require "test_helper"

class BriefCommitsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @workspace = workspaces(:one)
    @workspace.update!(workshop_enabled: true, jira_ai_actions_field_id: "customfield_10050")
    @project = @workspace.projects.create!(name: "BCM", color: "#333333",
      external_type: "jira", external_reference: "BCM")
    @task = @project.tasks.create!(name: "BCM-1 Thing", external_type: "jira", external_reference: "BCM-1")
    @brief = Brief.create!(task: @task, workspace: @workspace, version: 1, content: "concept")
    sign_in_as(users(:one)) # admin
  end

  def stub_writer(result)
    orig = JiraWriter.instance_method(:commit_brief)
    JiraWriter.define_method(:commit_brief) { |_b| result }
    yield
  ensure
    JiraWriter.define_method(:commit_brief, orig)
  end

  test "successful commit marks the brief briefed" do
    stub_writer({ ok: true, key: "BCM-1", url: "u" }) do
      post commit_jira_task_brief_path(@task, @brief)
    end
    assert_equal "briefed", @brief.reload.status
    assert_redirected_to(/workshop|jira_tasks/)
  end

  test "failed commit does NOT mark briefed and shows the error" do
    stub_writer({ ok: false, error: "403 Forbidden" }) do
      post commit_jira_task_brief_path(@task, @brief)
    end
    assert_equal "draft", @brief.reload.status
    follow_redirect!
    assert_match "403", response.body
  end

  test "non-admin is blocked" do
    sign_in_as(users(:two))
    stub_writer({ ok: true, key: "BCM-1" }) do
      post commit_jira_task_brief_path(@task, @brief)
    end
    assert_redirected_to root_path
    assert_equal "draft", @brief.reload.status
  end
end
