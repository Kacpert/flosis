# Emails to Flosis staff (SCRUM-71, designs/emails/staff.html): an invoice
# KSeF did not take. The charge went through, so the invoice stands; it has
# not reached KSeF, nor the organization's inbox, until staff retry it.
class StaffMailer < ApplicationMailer
  layout "billing_mailer"

  def ksef_failed(invoice)
    @invoice = invoice
    @why = "You get this because you are Flosis staff."
    @cta, @cta_url = "Open in Flosis admin", hidmin_workspace_url(invoice.workspace)
    recipients = User.where(flosis_staff: true).pluck(:email_address)
    return if recipients.empty?

    mail(to: recipients, from: ENV["BILLING_MAIL_FROM"].presence || self.class.default[:from],
         subject: "KSeF send failed: #{invoice.number} · #{invoice.workspace.name}")
  end
end
