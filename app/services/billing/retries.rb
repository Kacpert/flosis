# When a failed plan charge is tried again (SCRUM-71): the first attempt is
# day 1, then days 3, 5 and 7. Past day 7 the charge is unpaid and only a new
# card (or the admin's own retry) tries it again.
module Billing
  module Retries
    module_function

    def next_on(charge)
      first = charge.first_failed_at.in_time_zone.to_date
      day = charge.retry_day(Date.current)
      next_day = Billing::RETRY_ON_DAYS.find { |retry_day| retry_day > day }
      next_day && first + (next_day - 1)
    end
  end
end
