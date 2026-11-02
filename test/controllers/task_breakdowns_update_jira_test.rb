require "test_helper"

class TaskBreakdownsUpdateJiraTest < ActionDispatch::IntegrationTest
  setup do
    @workspace = workspaces(:one)
    @workspace.update!(workshop_enabled: true)
    # show_in_workshop explicitly: the column defaults to false because most
    # projects are born in Time & HR, and this test works a ticket on the
    # board — which only a Flosis project has.
    @project = @workspace.projects.create!(name: "UJ", color: "#666666",
      external_type: "jira", external_reference: "UJ", show_in_workshop: true,
      jira_ai_actions_field_id: "customfield_10050")
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
    # Workshop access is now "has a project to work in" rather than a flag —
    # fixture two_elvium would otherwise give this user Tasks on jira_project,
    # which is a real, valid Workshop membership and no longer represents
    # "without Workshop access" at all.
    ProjectMembership.where(user: users(:two)).destroy_all
    sign_in_as(users(:two)) # employee without Workshop access
    stub_writer({ ok: true, key: "UJ-1" }) do
      post jira_task_breakdown_update_jira_path(@task)
    end
    # require_product!(:workshop) bounces them to their Time & HR landing.
    assert_redirected_to time_entries_path
  end
end
