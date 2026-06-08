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

  test "report uses the current member rate, not the entry's snapshot" do
    # Entry logged while the member had a 0 rate (snapshot frozen at 0)...
    membership = project_memberships(:one_elvium)
    membership.update!(hourly_rate_cents: 0)
    stale = create_entry(users(:one), start: @day.to_time + 13.hours, hours: 4)
    assert_equal 0, stale.hourly_rate_cents, "precondition: entry snapshot is 0"

    # ...then the rate is set afterwards. The report must reflect the NEW rate
    # for ALL of this user's entries, ignoring per-entry snapshots entirely.
    membership.update!(hourly_rate_cents: 5_000) # $50/hr

    # users(:one) has 2h (from setup, snapshot $150) + 4h (this test, snapshot $0).
    # At the current $50 rate that is 6h * $50 = $300, proving snapshots are ignored.
    get reports_detailed_path(from: "2026-05-01", to: "2026-05-31", project_id: @project.id, user_id: users(:one).id)
    assert_response :success
    assert_match "300.00 USD", response.body
  end

  test "admin sees a total cost card with the project currency" do
    get reports_detailed_path(from: "2026-05-01", to: "2026-05-31", project_id: @project.id)
    assert_response :success
    assert_select ".stat-label", text: "Total Cost"
    assert_match "400.00 USD", response.body # 30_000 + 10_000 cents
  end

  test "admin sees per-user cost in the section header" do
    get reports_detailed_path(from: "2026-05-01", to: "2026-05-31", project_id: @project.id)
    assert_response :success
    assert_match "300.00 USD", response.body # user one: 2h @ $150
    assert_match "100.00 USD", response.body # user two: 1h @ $100
  end

  test "employee cannot see the detailed report at all" do
    sign_in_as(users(:two)) # employee
    get reports_detailed_path(from: "2026-05-01", to: "2026-05-31", project_id: @project.id)
    assert_redirected_to root_path
  end

  test "pdf export returns a pdf and does not embed the cost figures" do
    get export_pdf_reports_detailed_path(from: "2026-05-01", to: "2026-05-31", project_id: @project.id)
    assert_response :success
    assert_equal "application/pdf", response.media_type
    # The HTML shows "400.00 USD" etc.; the PDF must not contain those strings.
    assert_no_match "400.00 USD", response.body
    assert_no_match "300.00 USD", response.body
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
