require "test_helper"

class DiscordReminderDigestJobTest < ActiveJob::TestCase
  setup do
    @workspace = workspaces(:one)
    @workspace.update!(discord_user_token: "tok", discord_channel_id: "555")
  end

  # "today" = Tue 2026-06-09 → window = Mon 8, Fri 5, Thu 4.
  TODAY = Time.zone.local(2026, 6, 9, 11, 30)
  WINDOW = [ Date.new(2026, 6, 8), Date.new(2026, 6, 5), Date.new(2026, 6, 4) ].freeze

  def fake_client
    captured = []
    fake = Object.new
    fake.define_singleton_method(:configured?) { true }
    fake.define_singleton_method(:post) { |content| captured << content; true }
    fake.define_singleton_method(:captured) { captured }
    fake
  end

  def with_client(fake)
    original = DiscordGroupClient.method(:for)
    DiscordGroupClient.define_singleton_method(:for) { |*_a, **_k| fake }
    yield
  ensure
    DiscordGroupClient.define_singleton_method(:for, original)
  end

  # Force the per-user praise roll deterministically.
  def with_praise(value)
    original = DiscordReminderDigestJob.method(:praise?)
    DiscordReminderDigestJob.define_singleton_method(:praise?) { value }
    yield
  ensure
    DiscordReminderDigestJob.define_singleton_method(:praise?, original)
  end

  def recipient_for(user, threshold: 4.0)
    DiscordReminderRecipient.create!(
      workspace: @workspace, user: user,
      discord_user_id: "100#{user.id}", min_daily_hours: threshold
    )
  end

  def log_full_window(user)
    WINDOW.each do |d|
      @workspace.time_entries.create!(
        user: user, project: projects(:jira_project),
        started_at: d.to_time + 9.hours, stopped_at: d.to_time + 17.hours
      )
    end
  end

  test "posts one combined message with a reminder line and a count, logging a ping" do
    travel_to TODAY do
      r = recipient_for(users(:two)) # no entries → behind
      fake = fake_client
      with_client(fake) do
        with_praise(false) do
          assert_difference -> { r.discord_reminder_pings.count }, 1 do
            DiscordReminderDigestJob.perform_now(@workspace.id)
          end
        end
      end
      assert_equal 1, fake.captured.size, "exactly one combined message"
      msg = fake.captured.first
      assert_includes msg, "<@100#{users(:two).id}>"
      assert_includes msg, "Missing hours"
      assert_match(/reminder #1 this week, #1 this month/, msg)
    end
  end

  test "includes a praise section for a caught-up user when the roll hits" do
    travel_to TODAY do
      behind = recipient_for(users(:two))
      good = recipient_for(users(:one))
      log_full_window(users(:one)) # users(:one) caught up
      fake = fake_client
      with_client(fake) do
        with_praise(true) do
          DiscordReminderDigestJob.perform_now(@workspace.id)
        end
      end
      msg = fake.captured.first
      assert_includes msg, "Missing hours"          # behind section
      assert_includes msg, "Nice work"              # praise section
      assert_includes msg, "<@100#{users(:one).id}>" # the praised user
    end
  end

  test "does not include a caught-up user when the praise roll misses" do
    travel_to TODAY do
      recipient_for(users(:two))
      good = recipient_for(users(:one))
      log_full_window(users(:one))
      fake = fake_client
      with_client(fake) do
        with_praise(false) do
          DiscordReminderDigestJob.perform_now(@workspace.id)
        end
      end
      assert_not_includes fake.captured.first, "<@100#{users(:one).id}>"
      assert_not_includes fake.captured.first, "Nice work"
    end
  end

  test "skips approved-holiday days so a holidaying user is not flagged" do
    travel_to TODAY do
      recipient_for(users(:two))
      HolidayRequest.new(
        workspace: @workspace, user: users(:two),
        start_date: Date.new(2026, 6, 8), end_date: Date.new(2026, 6, 8),
        status: :approved, business_days: 1, reviewed_by: users(:one)
      ).save!(validate: false)
      [ Date.new(2026, 6, 5), Date.new(2026, 6, 4) ].each do |d|
        @workspace.time_entries.create!(user: users(:two), project: projects(:jira_project),
          started_at: d.to_time + 9.hours, stopped_at: d.to_time + 17.hours)
      end
      fake = fake_client
      with_client(fake) do
        with_praise(false) { DiscordReminderDigestJob.perform_now(@workspace.id) }
      end
      assert_empty fake.captured, "nobody behind, no praise → no message"
    end
  end

  test "posts nothing when nobody is behind and no praise" do
    travel_to TODAY do
      recipient_for(users(:two))
      log_full_window(users(:two))
      fake = fake_client
      with_client(fake) do
        with_praise(false) { DiscordReminderDigestJob.perform_now(@workspace.id) }
      end
      assert_empty fake.captured
    end
  end

  test "no-op when the client is not configured" do
    travel_to TODAY do
      recipient_for(users(:two))
      fake = Object.new
      fake.define_singleton_method(:configured?) { false }
      fake.define_singleton_method(:post) { |_| raise "should not post" }
      with_client(fake) do
        assert_nothing_raised { DiscordReminderDigestJob.perform_now(@workspace.id) }
      end
    end
  end
end
