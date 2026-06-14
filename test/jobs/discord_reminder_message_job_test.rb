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

  test "posts a mention message without disclosing the hours" do
    recipient = DiscordReminderRecipient.create!(
      workspace: workspaces(:one), user: users(:two),
      discord_user_id: "555", min_daily_hours: 4.0
    )

    fake = fake_client
    with_stubbed_client(fake) do
      DiscordReminderMessageJob.perform_now(recipient.id, "morning")
    end

    assert_equal 1, fake.captured.size
    msg = fake.captured.first
    assert_includes msg, "<@555>"
    assert_match(/log|hours|time/i, msg, "reminder should reference logging time")
    assert_not_includes msg, "4h", "must not disclose the threshold/hours"
  end

  test "praise variant sends a positive shout-out mentioning the user" do
    recipient = DiscordReminderRecipient.create!(
      workspace: workspaces(:one), user: users(:two),
      discord_user_id: "555", min_daily_hours: 4.0
    )

    fake = fake_client
    with_stubbed_client(fake) do
      DiscordReminderMessageJob.perform_now(recipient.id, "praise")
    end

    msg = fake.captured.first
    assert_includes msg, "<@555>"
    assert_not_includes msg, "missing", "praise should not mention missing hours"
  end

  test "afternoon variant mentions missing hours" do
    recipient = DiscordReminderRecipient.create!(
      workspace: workspaces(:one), user: users(:two),
      discord_user_id: "555", min_daily_hours: 4.0
    )

    fake = fake_client
    with_stubbed_client(fake) do
      DiscordReminderMessageJob.perform_now(recipient.id, "afternoon")
    end

    assert_match(/log|hours|time|missing/i, fake.captured.first)
  end

  test "reminders log a ping and include weekly/monthly counts" do
    recipient = DiscordReminderRecipient.create!(
      workspace: workspaces(:one), user: users(:two),
      discord_user_id: "555", min_daily_hours: 4.0
    )

    fake = fake_client
    with_stubbed_client(fake) do
      assert_difference -> { recipient.discord_reminder_pings.count }, 2 do
        DiscordReminderMessageJob.perform_now(recipient.id, "morning")
        DiscordReminderMessageJob.perform_now(recipient.id, "afternoon")
      end
    end

    assert_match(/reminder #2 this week, #2 this month/, fake.captured.last)
  end

  test "praise does not log a ping or include a count" do
    recipient = DiscordReminderRecipient.create!(
      workspace: workspaces(:one), user: users(:two),
      discord_user_id: "555", min_daily_hours: 4.0
    )

    fake = fake_client
    with_stubbed_client(fake) do
      assert_no_difference -> { recipient.discord_reminder_pings.count } do
        DiscordReminderMessageJob.perform_now(recipient.id, "praise")
      end
    end

    assert_no_match(/reminder #/, fake.captured.first)
  end

  test "no-ops when the recipient is missing" do
    fake = Object.new
    fake.define_singleton_method(:post) { |_| raise "should not be called" }
    with_stubbed_client(fake) do
      assert_nothing_raised { DiscordReminderMessageJob.perform_now(-1) }
    end
  end
end
