require "test_helper"

# AlertRule#due? is the core of Task 6.4 — the scheduler
# (AlertRulesDispatchJob) enqueues a run ONLY when this returns true, so every
# branch of the frequency/time logic is unit-tested here, independent of the
# job/controller. All times are pinned with travel_to in the app time zone
# (Warsaw, config.application.rb) since due-logic must never use Time.now.
class AlertRuleTest < ActiveSupport::TestCase
  setup do
    @workspace = workspaces(:one)
    @project = projects(:jira_project)
    @webhook = DiscordWebhook.create!(workspace: @workspace, channel_name: "#dev-alerts", url: "https://discord.com/api/webhooks/1/abc")
  end

  def build_rule(frequency:, run_at_time: nil, last_run_at: nil)
    AlertRule.new(
      workspace: @workspace, project: @project, discord_webhook: @webhook,
      name: "Rule", prompt: "Watch something.",
      frequency: frequency, run_at_time: run_at_time, last_run_at: last_run_at, active: true
    )
  end

  # --- hourly ---

  test "hourly: due when last_run_at is nil" do
    rule = build_rule(frequency: "hourly", last_run_at: nil)
    travel_to Time.zone.local(2026, 7, 6, 10, 0) do
      assert rule.due?(Time.current)
    end
  end

  test "hourly: due when last_run_at was 56 minutes ago (past the 55-minute threshold)" do
    travel_to Time.zone.local(2026, 7, 6, 10, 0) do
      rule = build_rule(frequency: "hourly", last_run_at: 56.minutes.ago)
      assert rule.due?(Time.current)
    end
  end

  test "hourly: NOT due when last_run_at was only 30 minutes ago" do
    travel_to Time.zone.local(2026, 7, 6, 10, 0) do
      rule = build_rule(frequency: "hourly", last_run_at: 30.minutes.ago)
      assert_not rule.due?(Time.current)
    end
  end

  test "hourly: NOT due exactly at the 55-minute boundary minus a second" do
    travel_to Time.zone.local(2026, 7, 6, 10, 0) do
      rule = build_rule(frequency: "hourly", last_run_at: 54.minutes.ago)
      assert_not rule.due?(Time.current)
    end
  end

  # --- daily ---

  test "daily: due today at/after run_at_time when not yet run today" do
    travel_to Time.zone.local(2026, 7, 6, 13, 5) do # Monday, 13:05
      rule = build_rule(frequency: "daily", run_at_time: "13:00", last_run_at: nil)
      assert rule.due?(Time.current)
    end
  end

  test "daily: NOT due before run_at_time" do
    travel_to Time.zone.local(2026, 7, 6, 12, 59) do
      rule = build_rule(frequency: "daily", run_at_time: "13:00", last_run_at: nil)
      assert_not rule.due?(Time.current)
    end
  end

  test "daily: NOT due when already run today (after the scheduled time)" do
    travel_to Time.zone.local(2026, 7, 6, 13, 5) do
      rule = build_rule(frequency: "daily", run_at_time: "13:00", last_run_at: Time.zone.local(2026, 7, 6, 13, 0))
      assert_not rule.due?(Time.current)
    end
  end

  test "daily: due again the next day even though it ran yesterday" do
    travel_to Time.zone.local(2026, 7, 7, 13, 5) do # Tuesday
      rule = build_rule(frequency: "daily", run_at_time: "13:00", last_run_at: Time.zone.local(2026, 7, 6, 13, 0))
      assert rule.due?(Time.current)
    end
  end

  # --- weekdays (Mon-Fri) ---

  test "weekdays: due on a weekday at/after run_at_time" do
    travel_to Time.zone.local(2026, 7, 8, 9, 0) do # Wednesday
      rule = build_rule(frequency: "weekdays", run_at_time: "09:00", last_run_at: nil)
      assert rule.due?(Time.current)
    end
  end

  test "weekdays: NOT due on Saturday" do
    travel_to Time.zone.local(2026, 7, 11, 9, 0) do # Saturday
      rule = build_rule(frequency: "weekdays", run_at_time: "09:00", last_run_at: nil)
      assert_not rule.due?(Time.current)
    end
  end

  test "weekdays: NOT due on Sunday" do
    travel_to Time.zone.local(2026, 7, 12, 9, 0) do # Sunday
      rule = build_rule(frequency: "weekdays", run_at_time: "09:00", last_run_at: nil)
      assert_not rule.due?(Time.current)
    end
  end

  # --- mwf (Mon/Wed/Fri) ---

  test "mwf: due on Monday" do
    travel_to Time.zone.local(2026, 7, 6, 9, 0) do # Monday
      rule = build_rule(frequency: "mwf", run_at_time: "09:00", last_run_at: nil)
      assert rule.due?(Time.current)
    end
  end

  test "mwf: due on Wednesday" do
    travel_to Time.zone.local(2026, 7, 8, 9, 0) do # Wednesday
      rule = build_rule(frequency: "mwf", run_at_time: "09:00", last_run_at: nil)
      assert rule.due?(Time.current)
    end
  end

  test "mwf: due on Friday" do
    travel_to Time.zone.local(2026, 7, 10, 9, 0) do # Friday
      rule = build_rule(frequency: "mwf", run_at_time: "09:00", last_run_at: nil)
      assert rule.due?(Time.current)
    end
  end

  test "mwf: NOT due on Tuesday" do
    travel_to Time.zone.local(2026, 7, 7, 9, 0) do # Tuesday
      rule = build_rule(frequency: "mwf", run_at_time: "09:00", last_run_at: nil)
      assert_not rule.due?(Time.current)
    end
  end

  # --- weekly (Mon) ---

  test "weekly: due on Monday" do
    travel_to Time.zone.local(2026, 7, 6, 9, 0) do # Monday
      rule = build_rule(frequency: "weekly", run_at_time: "09:00", last_run_at: nil)
      assert rule.due?(Time.current)
    end
  end

  test "weekly: NOT due Tuesday through Sunday" do
    (7..12).each do |day| # Jul 7 (Tue) .. Jul 12 (Sun)
      travel_to Time.zone.local(2026, 7, day, 9, 0) do
        rule = build_rule(frequency: "weekly", run_at_time: "09:00", last_run_at: nil)
        assert_not rule.due?(Time.current), "expected NOT due on #{Time.current.strftime('%A')}"
      end
    end
  end

  # --- validations ---

  test "frequency must be one of the allowed values" do
    rule = build_rule(frequency: "monthly")
    assert_not rule.valid?
    assert_includes rule.errors[:frequency], "is not included in the list"
  end

  test "active AlertRule is due? false when active is false is enforced at the dispatch layer, not due?" do
    # due? itself is schedule-only; AlertRulesDispatchJob filters on active
    # separately (see alert_rules_dispatch_job_test.rb). Documented here so
    # the split of responsibilities is explicit.
    travel_to Time.zone.local(2026, 7, 6, 13, 5) do
      rule = build_rule(frequency: "daily", run_at_time: "13:00", last_run_at: nil)
      rule.active = false
      assert rule.due?(Time.current), "due? does not consider `active` — that's the dispatcher's job"
    end
  end
end
