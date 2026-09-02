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

  # created_at defaults to well in the past: #due? refuses slots that predate the
  # rule (see "a rule does not fire for a slot..."), and every scheduling test
  # here is about an established rule, not a brand-new one.
  def build_rule(frequency:, run_at_time: nil, last_run_at: nil, created_at: Time.zone.local(2020, 1, 1))
    AlertRule.new(
      workspace: @workspace, project: @project, discord_webhook: @webhook,
      name: "Rule", prompt: "Watch something.",
      frequency: frequency, run_at_time: run_at_time, last_run_at: last_run_at, active: true,
      created_at: created_at
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

  # `frequency` is no longer user input — the schedule builder writes
  # schedule_mode/schedule_days/interval_hours, and AlertRule derives frequency
  # from them as a legacy mirror. An unknown frequency is therefore normalized
  # away rather than rejected; schedule_mode is what's validated now.
  test "an unrecognised frequency is normalized to a derived one" do
    rule = build_rule(frequency: "monthly")
    assert rule.valid?, rule.errors.full_messages.to_sentence
    assert_equal "daily", rule.frequency
    assert_equal "daily", rule.schedule_mode
  end

  test "schedule_mode must be one of the allowed values" do
    rule = build_rule(frequency: "daily", run_at_time: "09:00")
    rule.schedule_mode = "fortnightly"
    # normalize_schedule falls back to "daily" rather than leaving a bad value.
    assert rule.valid?
    assert_equal "daily", rule.schedule_mode
  end

  test "days mode requires at least one selected day" do
    rule = build_rule(frequency: "daily", run_at_time: "09:00")
    rule.schedule_mode = "days"
    rule.schedule_days = ""
    assert_not rule.valid?
    assert_includes rule.errors[:schedule_days], "must include at least one day"
  end

  test "interval mode clamps interval_hours into 1..24" do
    rule = build_rule(frequency: "daily")
    rule.schedule_mode = "interval"
    rule.interval_hours = 99
    assert rule.valid?, rule.errors.full_messages.to_sentence
    assert_equal 24, rule.interval_hours
  end

  test "interval mode only fires inside its window when one is set" do
    rule = build_rule(frequency: "daily")
    rule.schedule_mode = "interval"
    rule.interval_hours = 4
    rule.window_enabled = true
    rule.window_from = "09:00"
    rule.window_to = "18:00"
    rule.save!

    assert rule.due?(Time.zone.local(2026, 7, 6, 10, 0)), "inside the window with no previous run"
    # (build_rule dates the rule to 2020, so its first interval is long past.)
    assert_not rule.due?(Time.zone.local(2026, 7, 6, 20, 0)), "outside the window"
  end

  # Saving a "weekdays at 10:00" rule in the afternoon used to fire it within
  # five minutes, because the dispatcher saw today's slot as a missed run. For a
  # notifying rule that means pinging real people the moment you hit save.
  test "a rule does not fire for a slot that had already passed when it was created" do
    rule = build_rule(frequency: "daily", run_at_time: "10:00",
                      created_at: Time.zone.local(2026, 7, 6, 15, 10))
    rule.save!

    assert_not rule.due?(Time.zone.local(2026, 7, 6, 15, 15)), "today's 10:00 happened before the rule existed"
    assert rule.due?(Time.zone.local(2026, 7, 7, 10, 0)), "tomorrow's slot is its first real one"
  end

  test "a rule created before today's slot still fires today" do
    rule = build_rule(frequency: "daily", run_at_time: "10:00",
                      created_at: Time.zone.local(2026, 7, 6, 8, 0))
    rule.save!

    assert rule.due?(Time.zone.local(2026, 7, 6, 10, 1))
  end

  test "an interval rule waits out one interval after it is created" do
    rule = build_rule(frequency: "daily", created_at: Time.zone.local(2026, 7, 6, 12, 0))
    rule.schedule_mode = "interval"
    rule.interval_hours = 4
    rule.save!

    assert_not rule.due?(Time.zone.local(2026, 7, 6, 13, 0)), "one hour after creation is not four"
    assert rule.due?(Time.zone.local(2026, 7, 6, 16, 0))
  end

  test "schedule_label reads the way the card renders it" do
    weekdays = build_rule(frequency: "weekdays", run_at_time: "09:00")
    assert_equal "Weekdays · 09:00", weekdays.schedule_label

    interval = build_rule(frequency: "daily")
    interval.schedule_mode = "interval"
    interval.schedule_days = "Mon,Tue,Wed,Thu,Fri"
    interval.interval_hours = 4
    interval.window_enabled = true
    interval.window_from = "09:00"
    interval.window_to = "18:00"
    interval.valid?
    assert_equal "Weekdays · Every 4h · 09:00–18:00", interval.schedule_label
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
