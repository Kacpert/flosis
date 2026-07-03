# Scheduled every 5 minutes (config/recurring.yml, production block). Enqueues
# an AlertRuleRunJob for every ACTIVE rule whose schedule says it's due right
# now — `active` is filtered here (not inside AlertRule#due?, which is purely
# about the schedule) so the two concerns stay separate and independently
# testable.
class AlertRulesDispatchJob < ApplicationJob
  queue_as :default

  def perform
    now = Time.current
    AlertRule.active.find_each do |rule|
      AlertRuleRunJob.perform_later(rule.id) if rule.due?(now)
    end
  end
end
