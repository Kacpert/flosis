# SCRUM-71: an invoice KSeF did not take, sent again by Flosis staff. One
# KSeF refused takes the organization's billing details as they are now, so
# a NIP corrected after the refusal goes with the retry.
class Hidmin::InvoicesController < Hidmin::BaseController
  def retry_ksef
    invoice = Invoice.find(params[:id])
    return redirect_to(hidmin_workspace_path(invoice.workspace_id), flash: { clar_toast: "#{invoice.number} is already in KSeF" }) if invoice.sent_to_ksef?

    invoice.refresh_buyer! if invoice.ksef_status == "failed" && invoice.ksef_reference.blank?
    invoice.update!(ksef_status: "pending", ksef_error: nil)
    Ksef::SendInvoiceJob.perform_later(invoice)
    redirect_to hidmin_workspace_path(invoice.workspace_id), flash: { clar_toast: "Sending #{invoice.number} to KSeF again." }
  end
end
