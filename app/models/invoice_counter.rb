# Invoice numbers, gap-free within a calendar month, in the company's own
# format (Kacper, 2026-11-24: "FV/005/11/2026"): PREFIX/NNN/MM/YYYY. The
# prefix is INVOICE_NUMBER_PREFIX, "FS" (Flosis) by default: a series of its
# own, so a number Flosis gives is never one the company gives by hand. The month's row is locked while the next number
# is taken; it is made first, outside any transaction, so two charges issuing
# the month's first invoice at once never deadlock on MariaDB.
class InvoiceCounter < ApplicationRecord
  def self.ensure!(date)
    create_or_find_by!(month: date.beginning_of_month)
  end

  def self.next_number!(date)
    month = date.beginning_of_month
    transaction do
      counter = lock.find_by(month: month) || create_or_find_by!(month: month).lock!
      counter.increment!(:last_number)
      format("%s/%03d/%02d/%04d", prefix, counter.last_number, month.month, month.year)
    end
  end

  def self.prefix
    ENV["INVOICE_NUMBER_PREFIX"].presence || "FS"
  end
end
