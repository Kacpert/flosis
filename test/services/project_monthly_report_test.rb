require "test_helper"

class ProjectMonthlyReportTest < ActiveSupport::TestCase
  setup do
    @project = projects(:jira_project)
    @month = Date.new(2026, 6, 1)
    @from = @month.beginning_of_month
  end

  def entry(user, hours, at: @from + 9.hours)
    @project.time_entries.create!(
      workspace: @project.workspace, user: user,
      started_at: at, stopped_at: at + hours.hours
    )
  end

  def report
    ProjectMonthlyReport.new(project: @project, month: @month)
  end

  test "total_seconds sums completed entries in the month for the project" do
    entry(users(:one), 2)
    entry(users(:two), 1)
    entry(users(:one), 5, at: @month.prev_month.beginning_of_month + 9.hours) # other month, excluded
    assert_equal 3 * 3600, report.total_seconds
  end

  test "per_user_hours groups by user with percentages, sorted desc" do
    entry(users(:one), 3)
    entry(users(:two), 1)
    rows = report.per_user_hours
    assert_equal users(:one), rows.first[:user]
    assert_equal 3 * 3600, rows.first[:seconds]
    assert_in_delta 75.0, rows.first[:percent], 0.1
  end

  test "customer_acceptance_count counts jira tasks in that status updated in month" do
    @project.tasks.create!(name: "CA in month", external_type: "jira", external_reference: "CA-1",
      jira_status_name: "Customer Acceptance", jira_updated_at: @from + 2.days)
    @project.tasks.create!(name: "CA other month", external_type: "jira", external_reference: "CA-2",
      jira_status_name: "Customer Acceptance", jira_updated_at: @month.prev_month)
    @project.tasks.create!(name: "Other status", external_type: "jira", external_reference: "CA-3",
      jira_status_name: "In Progress", jira_updated_at: @from + 2.days)
    assert_equal 1, report.customer_acceptance_count
  end

  test "bugs_count counts Bug issue_type updated in month" do
    @project.tasks.create!(name: "Bug in month", external_type: "jira", external_reference: "B-1",
      issue_type: "Bug", jira_updated_at: @from + 1.day)
    @project.tasks.create!(name: "Story", external_type: "jira", external_reference: "B-2",
      issue_type: "Story", jira_updated_at: @from + 1.day)
    @project.tasks.create!(name: "Bug other month", external_type: "jira", external_reference: "B-3",
      issue_type: "Bug", jira_updated_at: @month.prev_month)
    assert_equal 1, report.bugs_count
  end
end
