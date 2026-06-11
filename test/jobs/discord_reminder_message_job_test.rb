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
    assert_includes fake.captured.first, "<@555>"
    assert_includes fake.captured.first, "missing hours"
    assert_not_includes fake.captured.first, "4h", "must not disclose the threshold/hours"
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

  test "afternoon variant uses the more urgent wording" do
    recipient = DiscordReminderRecipient.create!(
      workspace: workspaces(:one), user: users(:two),
      discord_user_id: "555", min_daily_hours: 4.0
    )

    fake = fake_client
    with_stubbed_client(fake) do
      DiscordReminderMessageJob.perform_now(recipient.id, "afternoon")
    end

    assert_includes fake.captured.first.downcase, "still missing hours"
  end

  test "no-ops when the recipient is missing" do
    fake = Object.new
    fake.define_singleton_method(:post) { |_| raise "should not be called" }
    with_stubbed_client(fake) do
      assert_nothing_raised { DiscordReminderMessageJob.perform_now(-1) }
    end
  end
end
