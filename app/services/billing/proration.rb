# A plan bought after the 1st pays for the days left, today included: joining on
# 20 Nov with a $300 plan pays 11 of 30 days, $110, and that is the month's limit.
# An upgrade pays the difference the same way.
module Billing
  module Proration
    module_function

    def days_left(date)
      date.end_of_month.day - date.day + 1
    end

    def amount(monthly_price, date)
      (BigDecimal(monthly_price.to_s) * days_left(date) / date.end_of_month.day).round(2)
    end

    def period(date)
      date..date.end_of_month
    end

    # "22–30 Nov", or "30 Nov" for one day.
    def label(period)
      first, last = period.begin, period.end
      return last.strftime("%-d %b") if first == last

      "#{first.day}–#{last.strftime('%-d %b')}"
    end
  end
end
