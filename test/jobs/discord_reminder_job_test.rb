require "test_helper"

class DiscordReminderJobTest < ActiveJob::TestCase
  setup do
    @workspace = workspaces(:one)
    # The job only acts on workspaces that have Discord configured.
    @workspace.update!(discord_user_token: "tok", discord_channel_id: "555")
  end

  # Swap DiscordGroupClient.for for a fake reporting the given configured? value.
  def with_client(configured:)
    fake = Object.new
    fake.define_singleton_method(:configured?) { configured }
    original = DiscordGroupClient.method(:for)
    DiscordGroupClient.define_singleton_method(:for) { |*_a, **_k| fake }
    yield
  ensure
    DiscordGroupClient.define_singleton_method(:for, original)
  end

  # Force the per-user praise roll to a fixed value for deterministic tests,
  # restoring the original method afterwards.
  def with_praise(value)
    original = DiscordReminderJob.instance_method(:praise?)
    DiscordReminderJob.define_method(:praise?) { value }
    yield
  ensure
    DiscordReminderJob.define_method(:praise?, original)
  end

  # 2026-06-08 is a Monday. With "today" = Tue 2026-06-09, the last 3 working
  # days ending yesterday are: Mon Jun 8, Fri Jun 5, Thu Jun 4.
  def monday
    Date.new(2026, 6, 8)
  end

  def window_days
    [ Date.new(2026, 6, 8), Date.new(2026, 6, 5), Date.new(2026, 6, 4) ]
  end

  def add_entry(user, date, hours)
    @workspace.time_entries.create!(
      user: user, project: projects(:jira_project),
      started_at: date.to_time + 9.hours,
      stopped_at: date.to_time + 9.hours + hours.hours
    )
  end

  def recipient_for(user, threshold: 4.0)
    DiscordReminderRecipient.create!(
      workspace: @workspace, user: user,
      discord_user_id: "100#{user.id}", min_daily_hours: threshold
    )
  end

  test "enqueues a message job for a user under threshold on a working day" do
    travel_to monday + 1.day do # today = Tue; window includes Mon
      r = recipient_for(users(:two), threshold: 4.0)
      add_entry(users(:two), monday, 1) # only 1h Monday -> under 4h

      with_client(configured: true) do
        assert_enqueued_with(job: DiscordReminderMessageJob, args: [ r.id, "morning" ]) do
          DiscordReminderJob.perform_now("morning")
        end
      end
    end
  end

  test "passes the afternoon variant through to the message job" do
    travel_to monday + 1.day do
      r = recipient_for(users(:two), threshold: 4.0)
      add_entry(users(:two), monday, 1)

      with_client(configured: true) do
        assert_enqueued_with(job: DiscordReminderMessageJob, args: [ r.id, "afternoon" ]) do
          DiscordReminderJob.perform_now("afternoon")
        end
      end
    end
  end

  test "does not enqueue when the user met the threshold every eligible day" do
    travel_to monday + 1.day do
      recipient_for(users(:two), threshold: 4.0)
      window_days.each { |d| add_entry(users(:two), d, 8) }

      with_client(configured: true) do
        with_praise(false) do
          assert_no_enqueued_jobs(only: DiscordReminderMessageJob) do
            DiscordReminderJob.perform_now
          end
        end
      end
    end
  end

  test "praises a doing-well user in the morning when the roll hits" do
    travel_to monday + 1.day do
      r = recipient_for(users(:two), threshold: 4.0)
      window_days.each { |d| add_entry(users(:two), d, 8) } # all good

      with_client(configured: true) do
        with_praise(true) do
          assert_enqueued_with(job: DiscordReminderMessageJob, args: [ r.id, "praise" ]) do
            DiscordReminderJob.perform_now("morning")
          end
        end
      end
    end
  end

  test "never praises in the afternoon run" do
    travel_to monday + 1.day do
      recipient_for(users(:two), threshold: 4.0)
      window_days.each { |d| add_entry(users(:two), d, 8) } # all good

      with_client(configured: true) do
        with_praise(true) do # even if the roll would hit
          assert_no_enqueued_jobs(only: DiscordReminderMessageJob) do
            DiscordReminderJob.perform_now("afternoon")
          end
        end
      end
    end
  end

  test "does not praise a good user when the roll misses" do
    travel_to monday + 1.day do
      recipient_for(users(:two), threshold: 4.0)
      window_days.each { |d| add_entry(users(:two), d, 8) }

      with_client(configured: true) do
        with_praise(false) do
          assert_no_enqueued_jobs(only: DiscordReminderMessageJob) do
            DiscordReminderJob.perform_now("morning")
          end
        end
      end
    end
  end

  test "skips approved-holiday days when evaluating" do
    travel_to monday + 1.day do
      recipient_for(users(:two), threshold: 4.0)
      # Approved holiday covering Mon Jun 8 (the day with no logged time).
      # Insert directly to bypass the not-in-the-past validation for a real past day.
      HolidayRequest.new(
        workspace: @workspace, user: users(:two),
        start_date: monday, end_date: monday, status: :approved,
        business_days: 1, reviewed_by: users(:one)
      ).save!(validate: false)
      # The other two working days in the window are fully logged.
      [ Date.new(2026, 6, 5), Date.new(2026, 6, 4) ].each { |d| add_entry(users(:two), d, 8) }

      with_client(configured: true) do
        assert_no_enqueued_jobs(only: DiscordReminderMessageJob) do
          DiscordReminderJob.perform_now
        end
      end
    end
  end

  test "no-ops when the client is not configured" do
    travel_to monday + 1.day do
      recipient_for(users(:two))
      add_entry(users(:two), monday, 0.5)

      with_client(configured: false) do
        assert_no_enqueued_jobs(only: DiscordReminderMessageJob) do
          DiscordReminderJob.perform_now
        end
      end
    end
  end
end
