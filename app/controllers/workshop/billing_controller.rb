# Settings › Billing (SCRUM-71): the organization's plan, card, top-ups,
# invoices, usage statements and billing details. Organization administrators
# only (anyone else gets a 404): it is the organization's money. The card is
# entered on Stripe's own page; a charge that needs 3-D Secure comes back
# through payment_return. Amounts and copy follow designs/admin/billing.html.
class Workshop::BillingController < Workshop::BaseController
  skip_before_action :require_current_project!, :require_project_member!
  before_action :require_workspace_admin!

  def show
    @account = current_workspace.billing
    @plans = Billing::Plans.new(current_workspace, user: current_user)
    @allowance = Billing::Allowance.for(current_workspace)
    @top_ups = Billing::TopUps.new(current_workspace)
    @balance = Billing::Ledger.balance(current_workspace)
    @invoices = current_workspace.invoices.newest_first.includes(billing_charge: :created_by)
    @statements = closed_months
    @open = params[:open].presence
  end

  def details
    account = current_workspace.billing
    account.assign_attributes(details_params)
    return back_to_details(account.errors.full_messages.to_sentence) unless account.valid?(:details)

    if account.vat.kind == :eu_reverse_charge && (account.vat_number_changed? || account.country_code_changed? || account.vat_checked_at.nil?)
      check = Billing::Vies.check(account.country_code, account.vat_number)
      return back_to_details("The EU's VIES could not check the VAT number just now. Try again in a few minutes.") if check.unavailable?
      return back_to_details("The EU's VIES does not know #{account.vat_number}: only businesses with a valid EU VAT number can buy.") unless check.valid?

      account.vat_checked_at = Time.current
    end
    account.save!(context: :details)
    flash[:clar_toast] = "Billing details saved"
    redirect_to workshop_billing_path
  end

  def card
    url = Billing::Card.new(current_workspace).page_url(
      success_url: "#{workshop_billing_card_return_url}?session_id={CHECKOUT_SESSION_ID}",
      cancel_url: workshop_billing_url
    )
    redirect_to url, allow_other_host: true, status: :see_other
  rescue Billing::NotReady, Stripe::StripeError => e
    redirect_to workshop_billing_path, alert: "Stripe's page could not be opened: #{e.message}"
  end

  def card_return
    retried = Billing::Card.new(current_workspace).save!(params[:session_id].to_s, return_url: workshop_billing_payment_return_url)
    return finish(retried) if retried

    flash[:clar_toast] = "Card saved: #{current_workspace.billing.reload.card_short}"
    redirect_to workshop_billing_path
  rescue Billing::NotReady, Stripe::StripeError => e
    redirect_to workshop_billing_path, alert: "The card was not saved: #{e.message}"
  end

  def plan
    plan = AiPlan.find(params[:plan_id])
    plans = Billing::Plans.new(current_workspace, user: current_user)
    preview = plans.preview(plan)
    charge = plans.choose!(plan, return_url: workshop_billing_payment_return_url)
    return finish(charge) if charge

    flash[:clar_toast] =
      case preview.kind
      when :next_month then "#{plan.name} starts on #{plans.next_first}."
      when :current then "#{plan.name} stays your plan."
      else "#{plan.name} is chosen. Add billing details and a card to activate it."
      end
    redirect_to workshop_billing_path
  rescue Billing::NotReady => e
    redirect_to workshop_billing_path, alert: e.message
  end

  def activate
    finish(Billing::Plans.new(current_workspace, user: current_user).activate!(return_url: workshop_billing_payment_return_url))
  rescue Billing::NotReady => e
    redirect_to workshop_billing_path, alert: e.message
  end

  def cancel
    plans = Billing::Plans.new(current_workspace, user: current_user)
    plans.cancel!
    plan = current_workspace.ai_plan
    flash[:notice] = "#{plan.name} is cancelled. It stays active until #{current_workspace.billing.plan_ends_on.strftime('%-d %b %Y')}, and nothing is charged after."
    redirect_to workshop_billing_path
  rescue Billing::NotReady => e
    redirect_to workshop_billing_path, alert: e.message
  end

  def keep
    plans = Billing::Plans.new(current_workspace, user: current_user)
    plans.keep!
    flash[:clar_toast] = "#{current_workspace.ai_plan&.name} is kept. Next charge #{plans.next_first}."
    redirect_to workshop_billing_path
  end

  def top_up
    finish(Billing::TopUps.new(current_workspace, user: current_user).buy!(params[:amount], return_url: workshop_billing_payment_return_url))
  rescue Billing::NotReady => e
    redirect_to workshop_billing_path, alert: e.message
  end

  def auto_top_up
    account = current_workspace.billing
    enabled = params[:enabled] == "1"
    amount = params[:amount].presence || account.auto_top_up_usd
    Billing::TopUps.new(current_workspace).configure!(enabled: enabled, amount: amount)
    flash[:clar_toast] = enabled ? "Automatic top-up on: #{Billing::Copy.whole(account.reload.auto_top_up_usd)} when the balance runs out" : "Automatic top-up off"
    redirect_to workshop_billing_path
  rescue Billing::NotReady => e
    redirect_to workshop_billing_path, alert: e.message
  end

  # Stripe sends the browser back here after 3-D Secure, with the payment's id.
  def payment_return
    charge = current_workspace.billing_charges.find_by!(stripe_payment_intent_id: params[:payment_intent].to_s)
    result = Billing.gateway.payment_result(charge.stripe_payment_intent_id)
    finish(Billing::Charger.new(current_workspace).settle!(charge, result))
  end

  def invoice
    invoice = current_workspace.invoices.find(params[:id])
    send_data InvoicePdf.new(invoice).render, filename: invoice.pdf_filename, type: "application/pdf", disposition: "attachment"
  end

  def statement
    month = Date.strptime(params[:month], "%Y-%m")
    raise ActiveRecord::RecordNotFound unless month < Date.current.beginning_of_month

    send_data UsageStatementPdf.new(current_workspace, month).render,
              filename: "usage-#{current_workspace.name.parameterize}-#{params[:month]}.pdf", type: "application/pdf", disposition: "attachment"
  end

  private

  def require_workspace_admin!
    head :not_found unless workspace_admin?
  end

  def details_params
    params.require(:billing_account).permit(:company_name, :street, :postal_code, :city, :country_code, :vat_number)
  end

  def back_to_details(message)
    flash[:alert] = message
    session[:billing_details_draft] = details_params.to_h
    redirect_to workshop_billing_path(open: "details")
  end

  # Where a charge landed, said as Billing says it.
  def finish(charge)
    case charge.status
    when "succeeded" then flash[:notice] = Billing::Copy.charged(charge)
    when "requires_action" then return redirect_to(charge.redirect_url, allow_other_host: true, status: :see_other)
    when "failed" then flash[:alert] = "The card was declined: #{charge.failure_message}. Nothing was charged."
    else flash[:notice] = "The payment is still processing. Billing shows it once it goes through."
    end
    redirect_to workshop_billing_path
  end

  # One usage statement per closed month with runs, newest first: the month,
  # how many projects, the organization's total.
  def closed_months
    costs = AiCosts.new(current_workspace)
    costs.months.select { |month| month < Date.current.beginning_of_month }.first(12).map do |month|
      summary = costs.month(month)
      { month: month, projects: summary.by_project.size, total: summary.total }
    end
  end
end
