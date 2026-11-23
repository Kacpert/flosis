# Scheduled every 5 minutes (config/recurring.yml, production block). Enqueues
# an AlertRuleRunJob for every ACTIVE rule whose schedule says it's due right
# now — `active` is filtered here (not inside AlertRule#due?, which is purely
# about the schedule) so the two concerns stay separate and independently
# testable.
class AlertRulesDispatchJob < ApplicationJob
  queue_as :default

  def perform
    now = Time.current
    paused = Hash.new { |cache, workspace_id| cache[workspace_id] = Billing::Allowance.paused_for?(Workspace.find_by(id: workspace_id)) }
    AlertRule.active.includes(:project).find_each do |rule|
      next unless rule.due?(now)

      # SCRUM-71: while the organization's AI is paused a due rule is not run;
      # its history says so, and the slot counts as taken.
      if paused[rule.project&.workspace_id]
        rule.alert_runs.create!(fired: false, summary: "Skipped: AI paused", status: "skipped", ran_at: now)
        rule.update!(last_run_at: now)
      else
        AlertRuleRunJob.perform_later(rule.id)
      end
    end
  end
end
