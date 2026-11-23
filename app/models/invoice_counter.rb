# Invoice numbers, gap-free within a calendar month: PREFIX/YYYY/MM/NNNN. The
# month's row is locked while the next number is taken, so two invoices issued
# at once never share or skip a number. INVOICE_NUMBER_PREFIX defaults to "FV".
class InvoiceCounter < ApplicationRecord
  def self.next_number!(date)
    month = date.beginning_of_month
    transaction do
      counter = lock.find_by(month: month) || create_or_find_by!(month: month).lock!
      counter.increment!(:last_number)
      format("%s/%04d/%02d/%04d", prefix, month.year, month.month, counter.last_number)
    end
  end

  def self.prefix
    ENV["INVOICE_NUMBER_PREFIX"].presence || "FV"
  end
end
