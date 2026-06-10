require "test_helper"

class DiscordReminderRecipientsControllerTest < ActionDispatch::IntegrationTest
  test "admin can create a recipient" do
    sign_in_as(users(:one))
    assert_difference "DiscordReminderRecipient.count", 1 do
      post discord_reminder_recipients_path, params: {
        discord_reminder_recipient: { user_id: users(:two).id, discord_user_id: "777", min_daily_hours: 6 }
      }
    end
    assert_redirected_to workspace_settings_path
  end

  test "admin can update a recipient" do
    sign_in_as(users(:one))
    r = DiscordReminderRecipient.create!(workspace: workspaces(:one), user: users(:two), discord_user_id: "1", min_daily_hours: 4)
    patch discord_reminder_recipient_path(r), params: { discord_reminder_recipient: { min_daily_hours: 8, active: false } }
    assert_redirected_to workspace_settings_path
    r.reload
    assert_equal 8.0, r.min_daily_hours.to_f
    assert_not r.active
  end

  test "admin can destroy a recipient" do
    sign_in_as(users(:one))
    r = DiscordReminderRecipient.create!(workspace: workspaces(:one), user: users(:two), discord_user_id: "1", min_daily_hours: 4)
    assert_difference "DiscordReminderRecipient.count", -1 do
      delete discord_reminder_recipient_path(r)
    end
    assert_redirected_to workspace_settings_path
  end

  test "employee is blocked" do
    sign_in_as(users(:two))
    assert_no_difference "DiscordReminderRecipient.count" do
      post discord_reminder_recipients_path, params: {
        discord_reminder_recipient: { user_id: users(:one).id, discord_user_id: "1", min_daily_hours: 4 }
      }
    end
    assert_redirected_to root_path
  end
end
