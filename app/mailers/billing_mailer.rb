# The billing emails to an organization's administrators (SCRUM-71), as
# designs/emails/{invoices,payments,usage}.html say them: an invoice (once KSeF
# has its number, the PDF attached), a payment that failed (each attempt), AI
# paused while a payment fails, an automatic top-up that failed, 80% of the
# month's limit (once a month) and the limit reached with no balance.
class BillingMailer < ApplicationMailer
  layout "billing_mailer"
  helper :application

  def invoice(invoice)
    @invoice = invoice
    workspace = invoice.workspace
    charge = invoice.billing_charge
    money = ->(amount) { Billing::Copy.money(amount) }
    attachments[invoice.pdf_filename] = { mime_type: "application/pdf", content: InvoicePdf.new(invoice).render }
    @why = "Sent to every organization administrator of #{workspace.name} when a payment goes through."
    @cta, @cta_url = "Open Billing", workshop_billing_url
    case charge.kind
    when "plan"
      month = charge.period_month.strftime("%B %Y")
      @heading = "Your invoice for #{charge.period_month.strftime('%B')}"
      @paragraphs = [ "We charged #{h charge.plan_name} for #{charge.period_from == charge.period_month ? month : "#{Billing::Copy.days(charge)} #{charge.period_month.year}"} to your card. The invoice is attached as a PDF, with its KSeF number and a QR code to check it." ]
      @after = [ "Your next charge is on #{charge.period_month.next_month.strftime('%-d %b %Y')}." ]
      subject = "Invoice #{invoice.number} · #{invoice.line_name}"
    when "upgrade"
      @heading = "Your invoice for the upgrade to #{charge.plan_name}"
      @paragraphs = [ "We charged the difference for #{Billing::Copy.days(charge)} to your card, and this month’s limit went up by #{money.(charge.net_usd)}. The invoice is attached as a PDF, with its KSeF number and a QR code to check it." ]
      subject = "Invoice #{invoice.number} · #{invoice.line_name}"
    when "top_up"
      amount = Billing::Copy.whole(charge.net_usd)
      @heading = "Your #{amount} top-up is ready"
      @paragraphs = [ "#{h(charge.created_by&.name || 'An admin')} bought a top-up. Top-up balance: <b>#{money.(Billing::Ledger.balance(workspace))}</b>. It is used only after the monthly limit is reached, at cost + 30%, and it never expires.".html_safe ]
      subject = "Invoice #{invoice.number} · Top-up #{amount}"
    when "auto_top_up"
      amount = Billing::Copy.whole(charge.net_usd)
      number = charge.automatic_number
      limit = AiMonthLimit.for(workspace, charge.succeeded_at.to_date)&.limit_usd
      back = charge.succeeded_at.to_date.next_month.beginning_of_month.strftime("%-d %b")
      if number >= Billing::AUTO_TOP_UPS_PER_MONTH
        @heading = "We topped up #{amount}, for the #{number.ordinalize} time this month"
        @paragraphs = [ "<b>Automatic top-ups are now paused until #{back}.</b> When this #{amount} runs out, AI pauses until someone buys a top-up by hand or the month ends.".html_safe ]
        subject = "We topped up #{amount} · automatic top-ups paused until #{back}"
        @cta, @cta_url = "Buy a top-up", workshop_billing_url(open: "top-up")
      else
        @heading = "We topped up #{amount}"
        @paragraphs = [ "#{h workspace.name} reached its #{money.(limit)} limit for #{charge.succeeded_at.strftime('%B')} and the top-up balance ran out, so we charged your automatic top-up. AI keeps running. This is automatic top-up <b>#{number} of #{Billing::AUTO_TOP_UPS_PER_MONTH}</b> this month.".html_safe ]
        subject = "We topped up #{amount}"
      end
    end
    notice(workspace, subject)
    invoice.update_column(:emailed_at, Time.current)
  end

  def payment_failed(charge)
    workspace = charge.workspace
    account = workspace.billing_account
    @why = "You get this because you are an organization administrator of #{workspace.name}. We send it again at every retry until the payment goes through."
    @cta, @cta_url = "Update card", workshop_billing_url
    @heading = "Payment failed, update your card"
    retrying = charge.next_retry_on.present?
    @paragraphs = [
      "We couldn’t charge <b>#{Billing::Copy.money(charge.gross_usd)}</b> to #{h account&.card_short || 'your card'} for #{h charge.plan_name}, #{charge.period_month.strftime('%B %Y')}.".html_safe,
      "The bank said: #{h charge.failure_message}.",
      (retrying ? "We retry the card over the next days, until #{(charge.retry_until + 1).strftime('%-d %b')}. Until the payment goes through, #{h workspace.name} can use up to <b>#{Billing::Copy.money(charge.grace_usd)}</b> of AI (15% of the plan), then AI pauses. Time & HR is never paused." :
                  "We have stopped retrying. AI is paused until the charge succeeds: change the card and we charge it straight away. Time & HR is never paused.").html_safe,
      "No invoice is issued until the payment succeeds."
    ]
    attempt = charge.attempts > 1 ? " (attempt #{charge.attempts})" : ""
    notice(workspace, "Payment failed, update your card#{attempt}")
  end

  def payment_paused(charge)
    workspace = charge.workspace
    @why = "You get this because you are an organization administrator of #{workspace.name}."
    @cta, @cta_url = "Update card", workshop_billing_url
    @heading = "AI is paused until the payment goes through."
    @paragraphs = [
      "#{h workspace.name} has used the <b>#{Billing::Copy.money(charge.grace_usd)}</b> of AI allowed while we retry the card, so new AI runs are paused. Runs already going finish, and Time & HR keeps working.".html_safe,
      "We keep retrying until #{(charge.retry_until + 1).strftime('%-d %b')}; after that, AI stays paused until the charge succeeds. Once it does, the full #{Billing::Copy.money(charge.plan_price_usd)} limit applies again."
    ]
    notice(workspace, "AI paused: your payment is still failing")
  end

  def auto_top_up_failed(charge)
    workspace = charge.workspace
    account = workspace.billing_account
    limit = AiMonthLimit.for(workspace, charge.created_at.to_date)&.limit_usd
    vat = account.vat
    @why = "You get this because you are an organization administrator of #{workspace.name}."
    @cta, @cta_url = "Open Billing", workshop_billing_url(open: "top-up")
    @heading = "We couldn’t top up #{Billing::Copy.whole(charge.net_usd)}."
    @paragraphs = [
      "#{h workspace.name} reached its #{Billing::Copy.money(limit)} limit for #{charge.created_at.strftime('%B')} and the top-up balance ran out, so we tried to charge your automatic top-up, <b>#{Billing::Copy.money(charge.gross_usd)}</b> (#{Billing::Copy.money(charge.net_usd)}#{vat.charged? ? " + #{vat.short_label}" : ''}), to #{h account.card_short}. The bank declined it.".html_safe,
      "New AI runs are paused until someone buys a top-up or changes the card. Runs already going finish, and Time & HR keeps working."
    ]
    notice(workspace, "Automatic top-up failed: AI is paused")
  end

  def usage_80(workspace)
    allowance = Billing::Allowance.for(workspace)
    limit = allowance.limit_usd
    month = Date.current
    @why = "You get this because you are an organization administrator of #{workspace.name}. It is sent once a month."
    @cta, @cta_url = "See Consumption", workshop_consumption_url
    @heading = "You’ve used 80% of this month’s AI limit (#{Billing::Copy.whole(limit * BigDecimal('0.8'))} of #{Billing::Copy.whole(limit)})."
    balance = Billing::Ledger.balance(workspace)
    @paragraphs = [
      "#{h workspace.name} has <b>#{Billing::Copy.money([ limit - allowance.plan_spend, 0 ].max)}</b> of AI left on #{h workspace.ai_plan&.name} in #{month.strftime('%B')}. Once the limit is reached, runs are paid from your top-up balance (#{Billing::Copy.money(balance)}), at cost + 30%.".html_safe,
      "With no balance left, new AI runs pause until #{allowance.back_on.strftime('%-d %b')}. Runs already going finish, and Time & HR is never paused."
    ]
    notice(workspace, "You've used 80% of this month's AI limit")
  end

  def limit_reached(workspace)
    allowance = Billing::Allowance.for(workspace)
    @why = "You get this because you are an organization administrator of #{workspace.name}."
    @cta, @cta_url = "Top up in Billing", workshop_billing_url(open: "top-up")
    @heading = "AI is paused for #{workspace.name} until you top up."
    @paragraphs = [
      "#{h workspace.name} has used its <b>#{Billing::Copy.money(allowance.limit_usd)}</b> limit for #{Date.current.strftime('%B')}, and the top-up balance is empty. New AI runs in the Workshop are paused; runs already going finish. Time & HR keeps working, and so do projects on their own Anthropic key.".html_safe,
      "Buy a $100, $200 or $300 top-up to start again now, or turn on automatic top-up for next time. Otherwise AI is back on #{allowance.back_on.strftime('%-d %b')}."
    ]
    notice(workspace, "AI paused: this month's AI limit is reached")
  end

  private

  def h(text) = ERB::Util.html_escape(text.to_s)

  def notice(workspace, subject)
    recipients = workspace.admin_users.pluck(:email_address)
    return if recipients.empty?

    mail(to: recipients, from: ENV["BILLING_MAIL_FROM"].presence || self.class.default[:from], subject: subject, template_name: "notice")
  end
end
