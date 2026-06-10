require "test_helper"

class DiscordReminderRecipientTest < ActiveSupport::TestCase
  def build_recipient(attrs = {})
    DiscordReminderRecipient.new({
      workspace: workspaces(:one),
      user: users(:two),
      discord_user_id: "123456789",
      min_daily_hours: 4.0
    }.merge(attrs))
  end

  test "valid with required attributes" do
    assert build_recipient.valid?
  end

  test "discord_user_id must be present and numeric" do
    assert_not build_recipient(discord_user_id: "").valid?
    assert_not build_recipient(discord_user_id: "abc").valid?
    assert build_recipient(discord_user_id: "42").valid?
  end

  test "min_daily_hours must be positive" do
    assert_not build_recipient(min_daily_hours: 0).valid?
    assert_not build_recipient(min_daily_hours: -1).valid?
  end

  test "user is unique per workspace" do
    build_recipient.save!
    dup = build_recipient(discord_user_id: "999")
    assert_not dup.valid?
  end

  test "defaults: active true, min_daily_hours 4.0" do
    r = DiscordReminderRecipient.new(workspace: workspaces(:one), user: users(:two), discord_user_id: "1")
    assert r.active
    assert_equal 4.0, r.min_daily_hours.to_f
  end
end
