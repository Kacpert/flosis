require "test_helper"

class JiraSyncServiceTest < ActiveSupport::TestCase
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
        url: "https://elvium.atlassian.net/browse/ELV-2"
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
  end

  def stub_client(issues, project_key = "ELV")
    expected_key = project_key
    expected_issues = issues
    Class.new do
      define_method(:fetch_issues) do |key|
        raise "Expected #{expected_key}, got #{key}" unless key == expected_key
        expected_issues
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
end
