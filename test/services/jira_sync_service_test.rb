require "test_helper"

class JiraSyncServiceTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @project = projects(:jira_project)
    @jira_issues = [
      {
        key: "ELV-1",
        summary: "Existing task updated",
        status_category: "indeterminate",
        status_name: "In Progress",
        assignee_email: "one@example.com",
        url: "https://elvium.atlassian.net/browse/ELV-1"
      },
      {
        key: "ELV-2",
        summary: "New feature",
        status_category: "new",
        status_name: "To Do",
        assignee_email: "two@example.com",
        url: "https://elvium.atlassian.net/browse/ELV-2",
        story_points: 5.0,
        jira_created_at: "2026-06-01T10:00:00.000+0000"
      },
      {
        key: "ELV-3",
        summary: "Done issue",
        status_category: "done",
        status_name: "Done",
        assignee_email: nil,
        url: "https://elvium.atlassian.net/browse/ELV-3"
      }
    ]
    @done_issues = [
      {
        key: "ELV-500",
        title: "Shipped last quarter",
        issue_type: "Story",
        assignee_email: "three@example.com",
        assignee_name: "Three Person",
        reporter_email: "four@example.com",
        reporter_name: "Four Person",
        story_points: 8.0,
        jira_created_at: "2026-01-01T10:00:00.000+0000",
        resolved_at: "2026-01-10T10:00:00.000+0000"
      }
    ]
  end

  def stub_client(issues, project_key = "ELV", done_issues: [])
    expected_key = project_key
    expected_issues = issues
    expected_done_issues = done_issues
    Class.new do
      define_method(:fetch_boards) { |_key| [] }
      define_method(:fetch_statuses) { {} }
      define_method(:fetch_sprint_issue_keys) { |_sprint_id| [] }
      define_method(:fetch_all_comments) { |_issue_key| [] }
      define_method(:resolve_story_points_field) { "customfield_10040" }
      define_method(:fetch_field_id) { |_name| "customfield_10178" } # AI estimation field
      define_method(:fetch_issues) do |key, story_points_field_id: nil|
        raise "Expected #{expected_key}, got #{key}" unless key == expected_key
        expected_issues
      end
      define_method(:fetch_recent_done_issues) do |key, since: nil, story_points_field_id: nil, ai_estimate_field_id: nil|
        raise "Expected #{expected_key}, got #{key}" unless key == expected_key
        expected_done_issues
      end
    end.new
  end

  test "creates new tasks from Jira issues" do
    mock_client = stub_client(@jira_issues)

    assert_difference -> { @project.tasks.count }, 2 do
      JiraSyncService.new(@project, client: mock_client).sync
    end

    new_task = @project.tasks.find_by(external_reference: "ELV-2")
    assert_equal "ELV-2 New feature", new_task.name
    assert_equal "jira", new_task.external_type
    assert_equal "https://elvium.atlassian.net/browse/ELV-2", new_task.external_url
    assert_equal "two@example.com", new_task.assignee_email
    assert_equal "To Do", new_task.jira_status_name
    assert_equal "active", new_task.status
  end

  test "updates existing synced tasks" do
    mock_client = stub_client(@jira_issues)

    JiraSyncService.new(@project, client: mock_client).sync

    existing = tasks(:jira_task).reload
    assert_equal "ELV-1 Existing task updated", existing.name
    assert_equal "In Progress", existing.jira_status_name
    assert_equal "active", existing.status
  end

  test "marks done issues as done" do
    mock_client = stub_client(@jira_issues)

    JiraSyncService.new(@project, client: mock_client).sync

    done_task = @project.tasks.find_by(external_reference: "ELV-3")
    assert_equal "done", done_task.status
    assert_equal "Done", done_task.jira_status_name
  end

  test "does not touch local tasks" do
    mock_client = stub_client(@jira_issues)

    JiraSyncService.new(@project, client: mock_client).sync

    local = tasks(:local_task).reload
    assert_equal "Daily standup", local.name
    assert_nil local.external_type
  end

  test "handles empty response gracefully" do
    mock_client = stub_client([])

    assert_nothing_raised do
      JiraSyncService.new(@project, client: mock_client).sync
    end
  end

  test "handles name collision by appending key" do
    @project.tasks.create!(name: "ELV-99 Colliding name", external_type: nil)

    mock_client = stub_client([
      { key: "ELV-99", summary: "Colliding name", status_category: "new", status_name: "To Do", assignee_email: nil, url: "https://elvium.atlassian.net/browse/ELV-99" }
    ])

    JiraSyncService.new(@project, client: mock_client).sync

    synced = @project.tasks.find_by(external_reference: "ELV-99", external_type: "jira")
    assert synced.present?
    assert_equal "ELV-99 Colliding name [ELV-99]", synced.name
  end

  test "fills story_points and jira_created_at on open issues" do
    mock_client = stub_client(@jira_issues)

    JiraSyncService.new(@project, client: mock_client).sync

    new_task = @project.tasks.find_by(external_reference: "ELV-2")
    assert_equal 5.0, new_task.story_points
    assert_equal Time.zone.parse("2026-06-01T10:00:00.000+0000"), new_task.jira_created_at
  end

  test "sync_delivered_issues upserts DeliveredIssue rows from done-issue payload" do
    mock_client = stub_client(@jira_issues, done_issues: @done_issues)

    assert_difference -> { DeliveredIssue.count }, 1 do
      JiraSyncService.new(@project, client: mock_client).sync_delivered_issues
    end

    delivered = @project.delivered_issues.find_by(jira_key: "ELV-500")
    assert delivered.present?
    assert_equal "Shipped last quarter", delivered.title
    assert_equal "Story", delivered.issue_type
    assert_equal "three@example.com", delivered.assignee_email
    assert_equal "Three Person", delivered.assignee_name
    assert_equal "four@example.com", delivered.reporter_email
    assert_equal "Four Person", delivered.reporter_name
    assert_equal 8.0, delivered.story_points
    assert_equal Time.zone.parse("2026-01-01T10:00:00.000+0000"), delivered.jira_created_at
    assert_equal Time.zone.parse("2026-01-10T10:00:00.000+0000"), delivered.resolved_at
  end

  test "HR-BOUNDARY: delivered issues never become tasks" do
    mock_client = stub_client(@jira_issues, done_issues: @done_issues)

    assert_no_difference -> { @project.tasks.count } do
      JiraSyncService.new(@project, client: mock_client).sync_delivered_issues
    end

    assert_nil @project.tasks.find_by(external_reference: "ELV-500")
  end

  test "sync_delivered_issues is idempotent" do
    mock_client = stub_client(@jira_issues, done_issues: @done_issues)

    JiraSyncService.new(@project, client: mock_client).sync_delivered_issues
    assert_no_difference -> { DeliveredIssue.count } do
      JiraSyncService.new(@project, client: mock_client).sync_delivered_issues
    end
  end

  test "full sync also syncs delivered issues without touching tasks count for done work" do
    mock_client = stub_client(@jira_issues, done_issues: @done_issues)

    JiraSyncService.new(@project, client: mock_client).sync

    assert_equal 1, @project.delivered_issues.where(jira_key: "ELV-500").count
    assert_nil @project.tasks.find_by(external_reference: "ELV-500")
  end

  # --- sprint trigger ---

  def stub_client_with_sprint_issue_keys(keys_by_sprint_id)
    Class.new do
      define_method(:fetch_boards) { |_key| [] }
      define_method(:fetch_statuses) { {} }
      define_method(:fetch_all_comments) { |_issue_key| [] }
      define_method(:fetch_sprint_issue_keys) { |sprint_id| keys_by_sprint_id[sprint_id] || [] }
    end.new
  end

  test "sprint trigger enqueues AutoEstimateJob for a task newly gaining a sprint_id on a non-design sprint" do
    @project.workspace.update!(estimation_trigger: "sprint")
    dev_board = jira_boards(:dev_board)
    dev_board.jira_sprints.create!(jira_sprint_id: 900, name: "Sprint 24", state: "active",
                                    start_date: 1.day.ago, end_date: 1.week.from_now)
    task = tasks(:jira_task)
    task.update!(sprint_id: nil, sprint_name: nil)

    mock_client = stub_client_with_sprint_issue_keys(900 => [ task.external_reference ])

    assert_enqueued_with(job: AutoEstimateJob, args: [ task.id ]) do
      JiraSyncService.new(@project, client: mock_client).sync_sprint_assignments
    end
  end

  test "sprint trigger does NOT enqueue for a task landing in a design sprint" do
    @project.workspace.update!(estimation_trigger: "sprint")
    task = tasks(:jira_task)
    task.update!(sprint_id: nil, sprint_name: nil)

    mock_client = stub_client_with_sprint_issue_keys(569 => [ task.external_reference ]) # design_sprint fixture

    assert_no_enqueued_jobs(only: AutoEstimateJob) do
      JiraSyncService.new(@project, client: mock_client).sync_sprint_assignments
    end
  end

  test "sprint trigger does NOT enqueue when estimation_trigger is not sprint" do
    @project.workspace.update!(estimation_trigger: "manual")
    dev_board = jira_boards(:dev_board)
    dev_board.jira_sprints.create!(jira_sprint_id: 901, name: "Sprint 25", state: "active",
                                    start_date: 1.day.ago, end_date: 1.week.from_now)
    task = tasks(:jira_task)
    task.update!(sprint_id: nil, sprint_name: nil)

    mock_client = stub_client_with_sprint_issue_keys(901 => [ task.external_reference ])

    assert_no_enqueued_jobs(only: AutoEstimateJob) do
      JiraSyncService.new(@project, client: mock_client).sync_sprint_assignments
    end
  end

  # "Estimate when added to a Development sprint" has to mean every unestimated
  # ticket sitting in one. Only counting tickets arriving from NO sprint missed
  # two cases that both happened in production: a ticket carried over from the
  # previous sprint, and one whose estimate run died against a broken CLI and
  # was never retried.
  test "sprint trigger enqueues an unestimated task that was already in the sprint" do
    @project.workspace.update!(estimation_trigger: "sprint")
    jira_boards(:dev_board).jira_sprints.create!(jira_sprint_id: 902, name: "Sprint 26", state: "active",
                                                 start_date: 1.day.ago, end_date: 1.week.from_now)
    task = tasks(:jira_task)
    task.update!(sprint_id: 902, sprint_name: "Sprint 26", ai_estimate_points: nil)

    mock_client = stub_client_with_sprint_issue_keys(902 => [ task.external_reference ])

    assert_enqueued_with(job: AutoEstimateJob, args: [ task.id ]) do
      JiraSyncService.new(@project, client: mock_client).sync_sprint_assignments
    end
  end

  # The other half of that: an estimate is spent once. Without this the sync
  # would re-run the AI over a full sprint every 15 minutes.
  test "sprint trigger never re-enqueues a task that already has an estimate" do
    @project.workspace.update!(estimation_trigger: "sprint")
    jira_boards(:dev_board).jira_sprints.create!(jira_sprint_id: 903, name: "Sprint 27", state: "active",
                                                 start_date: 1.day.ago, end_date: 1.week.from_now)
    task = tasks(:jira_task)
    task.update!(sprint_id: nil, sprint_name: nil, ai_estimate_points: 5)

    mock_client = stub_client_with_sprint_issue_keys(903 => [ task.external_reference ])

    assert_no_enqueued_jobs(only: AutoEstimateJob) do
      JiraSyncService.new(@project, client: mock_client).sync_sprint_assignments
    end
  end

  test "a sprint full of unestimated tasks is drained a few per sync, not all at once" do
    @project.workspace.update!(estimation_trigger: "sprint")
    jira_boards(:dev_board).jira_sprints.create!(jira_sprint_id: 904, name: "Sprint 28", state: "active",
                                                 start_date: 1.day.ago, end_date: 1.week.from_now)
    keys = (1..(JiraSyncService::AUTO_ESTIMATE_CAP + 5)).map do |i|
      key = "ELV-90#{i}"
      @project.tasks.create!(name: "#{key} thing", external_type: "jira", external_reference: key)
      key
    end

    mock_client = stub_client_with_sprint_issue_keys(904 => keys)

    assert_enqueued_jobs JiraSyncService::AUTO_ESTIMATE_CAP, only: AutoEstimateJob do
      JiraSyncService.new(@project, client: mock_client).sync_sprint_assignments
    end
  end

  # --- status trigger ---

  test "status trigger enqueues AutoEstimateJob when jira_status_name transitions into the configured trigger" do
    @project.workspace.update!(estimation_trigger: "status", estimation_status_trigger: "Ready for dev")
    task = tasks(:jira_task)
    task.update!(jira_status_name: "In Progress")

    issues = [ {
      key: task.external_reference, summary: "Existing task updated", status_category: "indeterminate",
      status_name: "Ready for dev", assignee_email: "one@example.com",
      url: "https://elvium.atlassian.net/browse/#{task.external_reference}"
    } ]
    mock_client = stub_client(issues)

    assert_enqueued_with(job: AutoEstimateJob, args: [ task.id ]) do
      JiraSyncService.new(@project, client: mock_client).sync_issues
    end
  end

  test "status trigger does NOT enqueue when already in the trigger status (no transition)" do
    @project.workspace.update!(estimation_trigger: "status", estimation_status_trigger: "Ready for dev")
    task = tasks(:jira_task)
    task.update!(jira_status_name: "Ready for dev")

    issues = [ {
      key: task.external_reference, summary: "Existing task updated", status_category: "indeterminate",
      status_name: "Ready for dev", assignee_email: "one@example.com",
      url: "https://elvium.atlassian.net/browse/#{task.external_reference}"
    } ]
    mock_client = stub_client(issues)

    assert_no_enqueued_jobs(only: AutoEstimateJob) do
      JiraSyncService.new(@project, client: mock_client).sync_issues
    end
  end

  test "status trigger does NOT enqueue when estimation_trigger is not status" do
    @project.workspace.update!(estimation_trigger: "manual", estimation_status_trigger: "Ready for dev")
    task = tasks(:jira_task)
    task.update!(jira_status_name: "In Progress")

    issues = [ {
      key: task.external_reference, summary: "Existing task updated", status_category: "indeterminate",
      status_name: "Ready for dev", assignee_email: "one@example.com",
      url: "https://elvium.atlassian.net/browse/#{task.external_reference}"
    } ]
    mock_client = stub_client(issues)

    assert_no_enqueued_jobs(only: AutoEstimateJob) do
      JiraSyncService.new(@project, client: mock_client).sync_issues
    end
  end

  # --- BugAttributionJob post-sync hook (Task 8.1) ---

  test "enqueues BugAttributionJob for a newly-synced Bug without an existing attribution" do
    issues = [ {
      key: "ELV-777", summary: "Export crashes on large CSV", status_category: "new", status_name: "To Do",
      assignee_email: nil, url: "https://elvium.atlassian.net/browse/ELV-777", issue_type: "Bug"
    } ]
    mock_client = stub_client(issues)

    assert_enqueued_with(job: BugAttributionJob, args: [ @project.id, "ELV-777" ]) do
      JiraSyncService.new(@project, client: mock_client).sync_issues
    end
  end

  test "does NOT enqueue BugAttributionJob for a non-Bug issue type" do
    issues = [ {
      key: "ELV-778", summary: "Add export button", status_category: "new", status_name: "To Do",
      assignee_email: nil, url: "https://elvium.atlassian.net/browse/ELV-778", issue_type: "Story"
    } ]
    mock_client = stub_client(issues)

    assert_no_enqueued_jobs(only: BugAttributionJob) do
      JiraSyncService.new(@project, client: mock_client).sync_issues
    end
  end

  test "does NOT enqueue BugAttributionJob for a Bug that already has an attribution" do
    BugAttribution.create!(project: @project, jira_key: "ELV-779", status: "done")

    issues = [ {
      key: "ELV-779", summary: "Existing crash bug", status_category: "new", status_name: "To Do",
      assignee_email: nil, url: "https://elvium.atlassian.net/browse/ELV-779", issue_type: "Bug"
    } ]
    mock_client = stub_client(issues)

    assert_no_enqueued_jobs(only: BugAttributionJob) do
      JiraSyncService.new(@project, client: mock_client).sync_issues
    end
  end

  test "caps BugAttributionJob enqueues at 3 per run" do
    issues = (1..5).map do |n|
      {
        key: "ELV-80#{n}", summary: "Bug number #{n}", status_category: "new", status_name: "To Do",
        assignee_email: nil, url: "https://elvium.atlassian.net/browse/ELV-80#{n}", issue_type: "Bug"
      }
    end
    mock_client = stub_client(issues)

    assert_enqueued_jobs 3, only: BugAttributionJob do
      JiraSyncService.new(@project, client: mock_client).sync_issues
    end
  end
end
