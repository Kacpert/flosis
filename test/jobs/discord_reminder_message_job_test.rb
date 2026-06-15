require "test_helper"

class DiscordReminderMessageJobTest < ActiveJob::TestCase
  # Lightweight stub helper: temporarily replace DiscordGroupClient.new with a
  # factory returning `fake`, restoring the original afterwards. The repo's
  # minitest build has no Object#stub, so we swap the singleton method by hand.
  def with_stubbed_client(fake)
    original = DiscordGroupClient.method(:for)
    DiscordGroupClient.define_singleton_method(:for) { |*_args, **_kw| fake }
    yield
  ensure
    DiscordGroupClient.define_singleton_method(:for, original)
  end

  def fake_client
    captured = []
    fake = Object.new
    fake.define_singleton_method(:post) { |content| captured << content; true }
    fake.define_singleton_method(:captured) { captured }
    fake
  end

  # "today" = Tue 2026-06-09, so the window is Mon 8, Fri 5, Thu 4.
  TODAY = Time.zone.local(2026, 6, 9, 10, 0)
  WINDOW = [ Date.new(2026, 6, 8), Date.new(2026, 6, 5), Date.new(2026, 6, 4) ].freeze

  def recipient(threshold: 4.0)
    DiscordReminderRecipient.create!(
      workspace: workspaces(:one), user: users(:two),
      discord_user_id: "555", min_daily_hours: threshold
    )
  end

  def log_full_window(user)
    WINDOW.each do |d|
      workspaces(:one).time_entries.create!(
        user: user, project: projects(:jira_project),
        started_at: d.to_time + 9.hours, stopped_at: d.to_time + 17.hours # 8h
      )
    end
  end

  test "posts a mention message without disclosing the hours (still behind)" do
    travel_to TODAY do
      r = recipient # no entries → under threshold now
      fake = fake_client
      with_stubbed_client(fake) { DiscordReminderMessageJob.perform_now(r.id, "morning") }

      assert_equal 1, fake.captured.size
      msg = fake.captured.first
      assert_includes msg, "<@555>"
      assert_match(/log|hours|time/i, msg)
      assert_not_includes msg, "4h", "must not disclose the threshold/hours"
    end
  end

  test "does NOT send a reminder if the user logged their hours during the delay" do
    travel_to TODAY do
      r = recipient
      log_full_window(users(:two)) # caught up by send time
      fake = fake_client
      with_stubbed_client(fake) do
        assert_no_difference -> { r.discord_reminder_pings.count } do
          DiscordReminderMessageJob.perform_now(r.id, "morning")
        end
      end
      assert_empty fake.captured, "should stay silent when no longer behind"
    end
  end

  test "praise variant sends a positive shout-out when the user is caught up" do
    travel_to TODAY do
      r = recipient
      log_full_window(users(:two)) # doing well → praise is earned
      fake = fake_client
      with_stubbed_client(fake) { DiscordReminderMessageJob.perform_now(r.id, "praise") }

      msg = fake.captured.first
      assert_includes msg, "<@555>"
      assert_not_includes msg, "missing", "praise should not mention missing hours"
    end
  end

  test "praise is withheld if the user has since fallen behind" do
    travel_to TODAY do
      r = recipient # no entries → behind → praise withheld
      fake = fake_client
      with_stubbed_client(fake) { DiscordReminderMessageJob.perform_now(r.id, "praise") }
      assert_empty fake.captured
    end
  end

  test "afternoon variant mentions missing hours (still behind)" do
    travel_to TODAY do
      r = recipient
      fake = fake_client
      with_stubbed_client(fake) { DiscordReminderMessageJob.perform_now(r.id, "afternoon") }
      assert_match(/log|hours|time|missing/i, fake.captured.first)
    end
  end

  test "reminders log a ping and include weekly/monthly counts" do
    travel_to TODAY do
      r = recipient
      fake = fake_client
      with_stubbed_client(fake) do
        assert_difference -> { r.discord_reminder_pings.count }, 2 do
          DiscordReminderMessageJob.perform_now(r.id, "morning")
          DiscordReminderMessageJob.perform_now(r.id, "afternoon")
        end
      end
      assert_match(/reminder #2 this week, #2 this month/, fake.captured.last)
    end
  end

  test "praise does not log a ping or include a count" do
    travel_to TODAY do
      r = recipient
      log_full_window(users(:two))
      fake = fake_client
      with_stubbed_client(fake) do
        assert_no_difference -> { r.discord_reminder_pings.count } do
          DiscordReminderMessageJob.perform_now(r.id, "praise")
        end
      end
      assert_no_match(/reminder #/, fake.captured.first)
    end
  end

  test "no-ops when the recipient is missing" do
    fake = Object.new
    fake.define_singleton_method(:post) { |_| raise "should not be called" }
    with_stubbed_client(fake) do
      assert_nothing_raised { DiscordReminderMessageJob.perform_now(-1) }
    end
  end
end
