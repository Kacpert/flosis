require "test_helper"

class AlertRulesDispatchJobTest < ActiveJob::TestCase
  setup do
    @workspace = workspaces(:one)
    @project = projects(:jira_project)
    @webhook = DiscordWebhook.create!(workspace: @workspace, channel_name: "#dev-alerts", url: "https://discord.com/api/webhooks/1/abc")
  end

  def build_rule(frequency:, run_at_time: nil, last_run_at: nil, active: true)
    AlertRule.create!(
      workspace: @workspace, project: @project, discord_webhook: @webhook,
      name: "Rule #{SecureRandom.hex(3)}", prompt: "Watch something.",
      frequency: frequency, run_at_time: run_at_time, last_run_at: last_run_at, active: active
    )
  end

  test "enqueues a run only for due AND active rules" do
    travel_to Time.zone.local(2026, 7, 6, 13, 5) do # Monday, 13:05
      due_active     = build_rule(frequency: "daily", run_at_time: "13:00")
      due_inactive    = build_rule(frequency: "daily", run_at_time: "13:00", active: false)
      not_due_active  = build_rule(frequency: "daily", run_at_time: "18:00")
      already_ran     = build_rule(frequency: "daily", run_at_time: "13:00", last_run_at: Time.zone.local(2026, 7, 6, 13, 1))

      AlertRulesDispatchJob.perform_now

      assert_enqueued_with(job: AlertRuleRunJob, args: [ due_active.id ])
      assert_no_enqueued_jobs_for(due_inactive)
      assert_no_enqueued_jobs_for(not_due_active)
      assert_no_enqueued_jobs_for(already_ran)
    end
  end

  test "enqueues nothing when no rules are due" do
    travel_to Time.zone.local(2026, 7, 6, 12, 0) do # before run_at_time
      build_rule(frequency: "daily", run_at_time: "13:00")

      AlertRulesDispatchJob.perform_now

      assert_no_enqueued_jobs
    end
  end

  test "hourly rules with a stale last_run_at are enqueued" do
    travel_to Time.zone.local(2026, 7, 6, 13, 0) do
      rule = build_rule(frequency: "hourly", last_run_at: 56.minutes.ago)

      AlertRulesDispatchJob.perform_now

      assert_enqueued_with(job: AlertRuleRunJob, args: [ rule.id ])
    end
  end

  private

  def assert_no_enqueued_jobs_for(rule)
    assert_empty enqueued_jobs.select { |j| j["job_class"] == "AlertRuleRunJob" && j["arguments"] == [ rule.id ] }
  end
end
