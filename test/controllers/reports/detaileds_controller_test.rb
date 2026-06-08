require "test_helper"

class Reports::DetailedsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @workspace = workspaces(:one)
    @project = projects(:jira_project) # currency USD
    @day = Date.new(2026, 5, 4)

    # users(:one) @ $150/hr, users(:two) @ $100/hr on jira_project (from fixtures).
    # 2h for user one => $300.00 = 30_000¢ ; 1h for user two => $100.00 = 10_000¢.
    @entry_one = create_entry(users(:one), start: @day.to_time + 9.hours, hours: 2)
    @entry_two = create_entry(users(:two), start: @day.to_time + 9.hours, hours: 1)

    sign_in_as(users(:one)) # owner / admin
  end

  test "per-entry billable amounts match the fixture rates" do
    # Sanity: entries snapshot the member project rate at save time.
    assert_equal 30_000, @entry_one.billable_amount_cents # 2h @ $150
    assert_equal 10_000, @entry_two.billable_amount_cents # 1h @ $100
  end

  test "show renders successfully for an admin" do
    get reports_detailed_path(from: "2026-05-01", to: "2026-05-31", project_id: @project.id)
    assert_response :success
  end

  private

  def create_entry(user, start:, hours:)
    @workspace.time_entries.create!(
      user: user,
      project: @project,
      started_at: start,
      stopped_at: start + hours.hours
    )
  end
end
