require "test_helper"

# WorkshopReport is a pure read model (Task 7.1): throughput/cost dashboard
# reading delivered work (delivered_issues, NEVER tasks — HR boundary) plus
# HR time-tracking (time_entries). See .superpowers/sdd/task-7.1-brief.md.
class WorkshopReportTest < ActiveSupport::TestCase
  setup do
    @project = projects(:jira_project)
    @one = users(:one)   # one@example.com
    @two = users(:two)   # two@example.com
    @now = Time.zone.local(2026, 7, 3, 12, 0, 0)
    travel_to @now
  end

  teardown { travel_back }

  def delivered(attrs = {})
    @project.delivered_issues.create!({
      jira_key: "ELV-#{rand(100_000)}",
      title: "Some feature",
      issue_type: "Story",
      story_points: 5,
      resolved_at: @now,
      jira_created_at: @now - 10.days
    }.merge(attrs))
  end

  def time_entry(user, hours:, started_at: @now.beginning_of_month + 1.day, rate_cents: 10_000)
    @project.time_entries.create!(
      workspace: @project.workspace, user: user,
      started_at: started_at, stopped_at: started_at + hours.hours,
      hourly_rate_cents: rate_cents
    )
  end

  def report(period: :month, developer: nil)
    WorkshopReport.new(project: @project, period: period, developer: developer)
  end

  # ---------------------------------------------------------------------
  # metrics
  # ---------------------------------------------------------------------

  test "metrics counts features delivered (non-Bug) with points, in period" do
    delivered(issue_type: "Story", story_points: 8, resolved_at: @now)
    delivered(issue_type: "Task", story_points: 3, resolved_at: @now)
    delivered(issue_type: "Bug", story_points: 2, resolved_at: @now) # excluded from features
    delivered(issue_type: "Story", story_points: 13, resolved_at: @now.prev_month) # out of period

    m = report.metrics
    assert_equal 2, m[:features_delivered_count]
    assert_equal 11, m[:features_delivered_points]
  end

  test "metrics completed story points sums all non-Bug delivered points in period" do
    delivered(issue_type: "Story", story_points: 5, resolved_at: @now)
    delivered(issue_type: "Task", story_points: 2, resolved_at: @now)
    delivered(issue_type: "Bug", story_points: 100, resolved_at: @now) # excluded

    assert_equal 7, report.metrics[:completed_story_points]
  end

  test "metrics new_bugs unions open tasks Bugs and delivered_issues Bugs by jira_created_at in period" do
    @project.tasks.create!(name: "Open bug", issue_type: "Bug", jira_created_at: @now, external_type: "jira", external_reference: "ELV-900")
    @project.tasks.create!(name: "Open story", issue_type: "Story", jira_created_at: @now, external_type: "jira", external_reference: "ELV-901")
    delivered(issue_type: "Bug", jira_created_at: @now)
    delivered(issue_type: "Bug", jira_created_at: @now.prev_month) # out of period

    assert_equal 2, report.metrics[:new_bugs]
  end

  test "metrics hours sums completed time_entries duration for the project in period" do
    time_entry(@one, hours: 3)
    time_entry(@two, hours: 2)
    time_entry(@one, hours: 100, started_at: @now.prev_month.beginning_of_month + 1.day) # out of period

    assert_in_delta 5.0, report.metrics[:hours], 0.01
  end

  test "metrics cost sums billable_amount_cents of completed time_entries in period" do
    time_entry(@one, hours: 2, rate_cents: 10_000) # 20000 cents
    time_entry(@two, hours: 1, rate_cents: 5_000)  # 5000 cents

    assert_equal 25_000, report.metrics[:cost_cents]
  end

  test "metrics scope to a focused developer" do
    dev1 = delivered(issue_type: "Story", story_points: 8, resolved_at: @now, assignee_email: @one.email_address)
    delivered(issue_type: "Story", story_points: 3, resolved_at: @now, assignee_email: @two.email_address)
    time_entry(@one, hours: 4)
    time_entry(@two, hours: 6)

    m = report(developer: @one).metrics
    assert_equal 1, m[:features_delivered_count]
    assert_equal 8, m[:features_delivered_points]
    assert_equal 8, m[:completed_story_points]
    assert_in_delta 4.0, m[:hours], 0.01
  end

  # ---------------------------------------------------------------------
  # developers
  # ---------------------------------------------------------------------

  test "developers built from time_entries users UNION delivered_issues assignees, matched by email" do
    time_entry(@one, hours: 3)
    delivered(issue_type: "Story", story_points: 5, resolved_at: @now, assignee_email: @two.email_address)

    devs = report.developers
    emails = devs.map { |d| d[:user]&.email_address }
    assert_includes emails, @one.email_address
    assert_includes emails, @two.email_address
  end

  test "developer sp is sum of non-Bug delivered story_points by assignee_email in period" do
    delivered(issue_type: "Story", story_points: 5, resolved_at: @now, assignee_email: @one.email_address)
    delivered(issue_type: "Task", story_points: 2, resolved_at: @now, assignee_email: @one.email_address)
    delivered(issue_type: "Bug", story_points: 100, resolved_at: @now, assignee_email: @one.email_address) # excluded
    delivered(issue_type: "Story", story_points: 999, resolved_at: @now.prev_month, assignee_email: @one.email_address) # out of period

    dev = report.developers.find { |d| d[:user] == @one }
    assert_equal 7, dev[:sp]
  end

  test "developer bugs_fixed is count of delivered Bugs by assignee in period" do
    delivered(issue_type: "Bug", resolved_at: @now, assignee_email: @one.email_address)
    delivered(issue_type: "Bug", resolved_at: @now, assignee_email: @one.email_address)
    delivered(issue_type: "Story", resolved_at: @now, assignee_email: @one.email_address)

    dev = report.developers.find { |d| d[:user] == @one }
    assert_equal 2, dev[:bugs_fixed]
  end

  test "developer bugs_created is reporter-fallback: Bugs reported by reporter_email across open tasks + delivered_issues" do
    # Task 8.2 will flip this to BugAttribution; until then it's the reporter fallback.
    time_entry(@one, hours: 1) # gives @one a developer row via time-tracking presence
    @project.tasks.create!(name: "Open bug reported by one", issue_type: "Bug", jira_created_at: @now,
      reporter_email: @one.email_address, external_type: "jira", external_reference: "ELV-910")
    delivered(issue_type: "Bug", jira_created_at: @now, reporter_email: @one.email_address)
    delivered(issue_type: "Story", jira_created_at: @now, reporter_email: @one.email_address) # not a bug, excluded
    delivered(issue_type: "Bug", jira_created_at: @now.prev_month, reporter_email: @one.email_address) # out of period

    dev = report.developers.find { |d| d[:user] == @one }
    assert_equal 2, dev[:bugs_created]
  end

  test "developer hours and cost_cents come from completed time_entries" do
    time_entry(@one, hours: 3, rate_cents: 8_000)
    time_entry(@one, hours: 2, rate_cents: 8_000)

    dev = report.developers.find { |d| d[:user] == @one }
    assert_in_delta 5.0, dev[:hours], 0.01
    assert_equal 40_000, dev[:cost_cents] # (3*8000)+(2*8000) = 24000+16000
  end

  test "developers filters to a single developer when developer: is given" do
    time_entry(@one, hours: 1)
    time_entry(@two, hours: 1)

    devs = report(developer: @one).developers
    assert_equal [ @one ], devs.map { |d| d[:user] }
  end

  # ---------------------------------------------------------------------
  # trend
  # ---------------------------------------------------------------------

  test "trend granularity months buckets sum of story_points by resolved_at calendar month" do
    delivered(issue_type: "Story", story_points: 5, resolved_at: @now)
    delivered(issue_type: "Story", story_points: 3, resolved_at: @now)
    delivered(issue_type: "Story", story_points: 2, resolved_at: @now.prev_month)

    points = report.trend(granularity: "months", range: 6)
    assert_equal 6, points.size
    current_point = points.last
    assert_equal 8, current_point[:sp]
    prev_point = points[-2]
    assert_equal 2, prev_point[:sp]
    assert current_point.key?(:label)
    assert current_point.key?(:full)
    assert current_point.key?(:bugs_created)
    assert current_point.key?(:bugs_fixed)
  end

  test "trend months excludes Bug issue_type from sp but counts bugs_fixed/bugs_created series" do
    delivered(issue_type: "Bug", story_points: 100, resolved_at: @now, assignee_email: @one.email_address)
    delivered(issue_type: "Story", story_points: 5, resolved_at: @now)

    points = report.trend(granularity: "months", range: 6)
    current_point = points.last
    assert_equal 5, current_point[:sp]
    assert_equal 1, current_point[:bugs_fixed]
  end

  test "trend granularity sprints buckets by resolved_at between sprint start/end date" do
    board = jira_boards(:design_board)
    sprint = jira_sprints(:design_sprint) # 2026-03-01..2026-03-15, board: design_board (project jira_project)
    in_window = sprint.start_date + 2.days
    delivered(issue_type: "Story", story_points: 4, resolved_at: in_window)
    delivered(issue_type: "Story", story_points: 999, resolved_at: sprint.end_date + 30.days) # outside sprint window

    points = report.trend(granularity: "sprints", range: 8)
    sprint_point = points.find { |p| p[:full] == sprint.name }
    refute_nil sprint_point
    assert_equal 4, sprint_point[:sp]
  end

  test "trend sprints skips sprints with nil start_date or end_date" do
    board = jira_boards(:design_board)
    JiraSprint.create!(jira_board: board, jira_sprint_id: 9999, name: "No dates", state: "closed", start_date: nil, end_date: nil)
    # A sprint with only ONE nil date must also be excluded — the guard must be
    # "neither date nil", not "not (both nil)". A partial-nil sprint that slips
    # through would NoMethodError on the nil date when building the window.
    JiraSprint.create!(jira_board: board, jira_sprint_id: 9998, name: "Half dates", state: "closed",
                       start_date: nil, end_date: @now.to_date)

    assert_nothing_raised { report.trend(granularity: "sprints", range: 8) }
    labels = report.trend(granularity: "sprints", range: 8).map { |p| p[:full] }
    refute_includes labels, "No dates"
    refute_includes labels, "Half dates"
  end

  test "trend filters by developer via assignee_email" do
    delivered(issue_type: "Story", story_points: 5, resolved_at: @now, assignee_email: @one.email_address)
    delivered(issue_type: "Story", story_points: 9, resolved_at: @now, assignee_email: @two.email_address)

    points = report(developer: @one).trend(granularity: "months", range: 6)
    assert_equal 5, points.last[:sp]
  end

  # ---------------------------------------------------------------------
  # delivered
  # ---------------------------------------------------------------------

  test "delivered lists non-Bug issues with points in period: key/title/dev/pts/merged/prs" do
    issue = delivered(jira_key: "ELV-42", title: "Aggregated export", issue_type: "Story",
      story_points: 8, resolved_at: @now, assignee_email: @one.email_address)
    delivered(issue_type: "Bug", story_points: 3, resolved_at: @now) # excluded
    delivered(issue_type: "Story", story_points: nil, resolved_at: @now) # no points, excluded per brief ("with points")

    PrReview.create!(workspace: @project.workspace, pr_number: 1, pr_branch: "feat/ELV-42-export", outcome: "good")
    PrReview.create!(workspace: @project.workspace, pr_number: 2, pr_title: "ELV-42 follow-up", outcome: "good")
    PrReview.create!(workspace: @project.workspace, pr_number: 3, pr_branch: "feat/other-issue", outcome: "good")

    rows = report.delivered
    assert_equal 1, rows.size
    row = rows.first
    assert_equal "ELV-42", row[:key]
    assert_equal "Aggregated export", row[:title]
    assert_equal @one, row[:dev]
    assert_equal 8, row[:pts]
    assert_equal issue.resolved_at, row[:merged]
    assert_equal 2, row[:prs]
  end

  test "delivered is empty when nothing delivered in period" do
    assert_equal [], report.delivered
  end

  test "delivered filters by developer" do
    delivered(issue_type: "Story", story_points: 5, resolved_at: @now, assignee_email: @one.email_address)
    delivered(issue_type: "Story", story_points: 5, resolved_at: @now, assignee_email: @two.email_address)

    rows = report(developer: @one).delivered
    assert_equal 1, rows.size
    assert_equal @one, rows.first[:dev]
  end

  # ---------------------------------------------------------------------
  # period handling
  # ---------------------------------------------------------------------

  test "period :month uses the current calendar month window" do
    delivered(issue_type: "Story", story_points: 5, resolved_at: @now.beginning_of_month)
    delivered(issue_type: "Story", story_points: 7, resolved_at: @now.end_of_month)
    delivered(issue_type: "Story", story_points: 999, resolved_at: @now.next_month)

    assert_equal 12, report(period: :month).metrics[:completed_story_points]
  end

  test "period :sprint uses the active JiraSprint window when present" do
    travel_to Time.zone.local(2026, 3, 5, 12, 0, 0) do
      sprint = jira_sprints(:design_sprint) # active, 2026-03-01..2026-03-15
      delivered(issue_type: "Story", story_points: 6, resolved_at: sprint.start_date + 1.day)
      delivered(issue_type: "Story", story_points: 999, resolved_at: sprint.end_date + 1.day)

      assert_equal 6, report(period: :sprint).metrics[:completed_story_points]
    end
  end

  test "period :sprint falls back to calendar month when there is no active sprint" do
    project = projects(:plain_project) # no jira_boards/sprints
    delivered_issue = project.delivered_issues.create!(jira_key: "INT-1", title: "x", issue_type: "Story",
      story_points: 4, resolved_at: @now)

    r = WorkshopReport.new(project: project, period: :sprint)
    assert_equal 4, r.metrics[:completed_story_points]
  end
end
