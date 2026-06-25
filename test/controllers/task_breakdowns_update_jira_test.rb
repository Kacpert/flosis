require "test_helper"

class TaskBreakdownsUpdateJiraTest < ActionDispatch::IntegrationTest
  setup do
    @workspace = workspaces(:one)
    @workspace.update!(workshop_enabled: true, jira_ai_actions_field_id: "customfield_10050")
    @project = @workspace.projects.create!(name: "UJ", color: "#666666",
      external_type: "jira", external_reference: "UJ")
    @task = @project.tasks.create!(name: "UJ-1 Thing", external_type: "jira", external_reference: "UJ-1")
    @task.task_drafts.create!(source: TaskDraft::BREAKDOWN_SOURCE,
      content: { needs_breakdown: false, total_points: 2, subtasks: [] }.to_json)
    sign_in_as(users(:one))
  end

  def stub_writer(result)
    orig = JiraWriter.instance_method(:commit_breakdown)
    JiraWriter.define_method(:commit_breakdown) { |_t| result }
    yield
  ensure
    JiraWriter.define_method(:commit_breakdown, orig)
  end

  test "update_jira success shows a notice" do
    stub_writer({ ok: true, key: "UJ-1" }) do
      post jira_task_breakdown_update_jira_path(@task)
    end
    assert_response :redirect
    follow_redirect!
    assert_match "UJ-1", response.body
  end

  test "update_jira failure shows an alert" do
    stub_writer({ ok: false, error: "403" }) do
      post jira_task_breakdown_update_jira_path(@task)
    end
    follow_redirect!
    assert_match "403", response.body
  end

  test "employee is blocked" do
    sign_in_as(users(:two))
    stub_writer({ ok: true, key: "UJ-1" }) do
      post jira_task_breakdown_update_jira_path(@task)
    end
    assert_redirected_to root_path
  end
end
