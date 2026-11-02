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

  # 2026-06-09 is a Tuesday → window = Mon 8, Fri 5, Thu 4.
  test "under_threshold_now? reflects current logged hours" do
    travel_to Time.zone.local(2026, 6, 9, 10, 0) do
      r = build_recipient(min_daily_hours: 4.0)
      r.save!
      assert r.under_threshold_now?, "no entries → under threshold"

      [ Date.new(2026, 6, 8), Date.new(2026, 6, 5), Date.new(2026, 6, 4) ].each do |d|
        workspaces(:one).time_entries.create!(
          user: users(:two), project: projects(:jira_project),
          started_at: d.to_time + 9.hours, stopped_at: d.to_time + 17.hours
        )
      end
      assert_not r.under_threshold_now?, "8h each day → not under threshold"
    end
  end

  test "under_threshold_now? skips approved-holiday days" do
    travel_to Time.zone.local(2026, 6, 9, 10, 0) do
      r = build_recipient(min_daily_hours: 4.0)
      r.save!
      # Behind on Mon 8 only, but on approved holiday that day; other two full.
      HolidayRequest.new(
        workspace: workspaces(:one), user: users(:two),
        start_date: Date.new(2026, 6, 8), end_date: Date.new(2026, 6, 8),
        status: :approved, business_days: 1, reviewed_by: users(:one)
      ).save!(validate: false)
      [ Date.new(2026, 6, 5), Date.new(2026, 6, 4) ].each do |d|
        workspaces(:one).time_entries.create!(
          user: users(:two), project: projects(:jira_project),
          started_at: d.to_time + 9.hours, stopped_at: d.to_time + 17.hours
        )
      end
      assert_not r.under_threshold_now?, "holiday day excluded; rest are full"
    end
  end
end
