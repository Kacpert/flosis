# Wording for Consumption and the Flosis-admin billing pages (SCRUM-70).
module ConsumptionHelper
  # "Today 14:12", "Yest. 22:00", "17 Nov 08:15".
  def consumption_when(time)
    time = time.in_time_zone
    day = if time.to_date == Date.current then "Today"
    elsif time.to_date == Date.yesterday then "Yest."
    else time.strftime("%-d %b")
    end
    "#{day} #{time.strftime('%H:%M')}"
  end

  def consumption_month(date, current: Date.current.beginning_of_month)
    label = date.strftime("%B %Y")
    date.beginning_of_month == current ? "#{label} (this month)" : label
  end

  # How much of the limit an amount is, in whole percent; nil without a limit.
  # A $0 limit (a free plan) is all used by anything spent at all.
  def consumption_percent(amount, limit)
    return if limit.nil?
    return amount.to_d.positive? ? 100 : 0 if limit.to_d.zero?

    (amount.to_d / limit.to_d * 100).round
  end

  # The badge a run earned in the run list, in the designs' words.
  def consumption_run_badges(run)
    badges = []
    badges << "DELETED" if run.item_deleted?
    badges << { "stopped" => "STOPPED", "failed" => "FAILED", "timed_out" => "TIMED OUT" }[run.status]
    badges << "OWN KEY" if run.own_key
    badges.compact
  end

  # Who set a run going: a person, or the automation by its own name.
  def consumption_started_by(run)
    run.automation.presence || run.started_by&.name || "Someone no longer here"
  end
end
