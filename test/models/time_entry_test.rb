require "test_helper"

class TimeEntryTest < ActiveSupport::TestCase
  test "effective_rate_cents returns project membership rate" do
    entry = TimeEntry.new(
      user: users(:one),
      project: projects(:jira_project),
      workspace: workspaces(:one),
      started_at: Time.current
    )
    # one_elvium fixture has hourly_rate_cents: 15000
    assert_equal 15000, entry.effective_rate_cents
  end

  test "effective_rate_cents returns 0 when no membership" do
    entry = TimeEntry.new(
      user: users(:two),
      project: projects(:plain_project),
      workspace: workspaces(:one),
      started_at: Time.current
    )
    assert_equal 0, entry.effective_rate_cents
  end

  test "effective_rate_cents prefers entry own rate" do
    entry = TimeEntry.new(
      user: users(:one),
      project: projects(:jira_project),
      workspace: workspaces(:one),
      started_at: Time.current,
      hourly_rate_cents: 99999
    )
    assert_equal 99999, entry.effective_rate_cents
  end

  test "set_hourly_rate locks rate from membership on stop" do
    entry = TimeEntry.create!(
      user: users(:one),
      project: projects(:jira_project),
      workspace: workspaces(:one),
      started_at: 1.hour.ago,
      stopped_at: Time.current
    )
    assert_equal 15000, entry.hourly_rate_cents
  end

  test "billable_amount_cents calculates without billable check" do
    entry = TimeEntry.new(
      duration_seconds: 3600,
      hourly_rate_cents: 10000,
      user: users(:one),
      project: projects(:jira_project),
      workspace: workspaces(:one),
      started_at: 1.hour.ago,
      stopped_at: Time.current
    )
    assert_equal 10000, entry.billable_amount_cents
  end
end
