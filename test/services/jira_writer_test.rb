require "test_helper"

class JiraWriterTest < ActiveSupport::TestCase
  setup do
    @workspace = workspaces(:one)
    @project = @workspace.projects.create!(name: "JW", color: "#111111",
      external_type: "jira", external_reference: "JW")
    @workspace.update!(jira_ai_actions_field_id: "customfield_10050")
  end

  # Minimal fake client recording calls.
  def fake_client(create: { ok: true, key: "JW-1", url: "u" },
                  update: { ok: true }, action: { ok: true })
    c = Object.new
    calls = { create: 0, update: 0, action: nil }
    c.define_singleton_method(:create_issue) { |**_k| calls[:create] += 1; create }
    c.define_singleton_method(:update_issue_description) { |**_k| calls[:update] += 1; update }
    c.define_singleton_method(:add_ai_action) { |**k| calls[:action] = k; action }
    c.define_singleton_method(:fetch_field_id) { |_n| "customfield_10050" }
    c.define_singleton_method(:calls) { calls }
    c
  end

  test "new-idea task creates an issue and backfills the reference" do
    task = @project.tasks.create!(name: "Idea")
    brief = Brief.create!(task: task, workspace: @workspace, version: 1, content: "concept")
    c = fake_client
    res = JiraWriter.new(workspace: @workspace, client: c).commit_brief(brief)
    assert res[:ok], res.inspect
    assert_equal 1, c.calls[:create]
    assert_equal 0, c.calls[:update]
    assert_equal "JW-1", task.reload.external_reference
    assert_equal "jira", task.external_type
    assert_equal "Briefed", c.calls[:action][:value]
  end

  test "existing task updates the description" do
    task = @project.tasks.create!(name: "JW-7 Existing", external_type: "jira", external_reference: "JW-7")
    brief = Brief.create!(task: task, workspace: @workspace, version: 1, content: "concept")
    c = fake_client
    res = JiraWriter.new(workspace: @workspace, client: c).commit_brief(brief)
    assert res[:ok]
    assert_equal 0, c.calls[:create]
    assert_equal 1, c.calls[:update]
  end

  test "a failed write returns not-ok and does not mark briefed" do
    task = @project.tasks.create!(name: "JW-7 Existing", external_type: "jira", external_reference: "JW-7")
    brief = Brief.create!(task: task, workspace: @workspace, version: 1, content: "x")
    c = fake_client(update: { ok: false, error: "403 Forbidden" })
    res = JiraWriter.new(workspace: @workspace, client: c).commit_brief(brief)
    assert_not res[:ok]
    assert_equal "403 Forbidden", res[:error]
  end

  test "missing field id is discovered and cached on the workspace" do
    @workspace.update!(jira_ai_actions_field_id: nil)
    task = @project.tasks.create!(name: "JW-7 Existing", external_type: "jira", external_reference: "JW-7")
    brief = Brief.create!(task: task, workspace: @workspace, version: 1, content: "x")
    JiraWriter.new(workspace: @workspace, client: fake_client).commit_brief(brief)
    assert_equal "customfield_10050", @workspace.reload.jira_ai_actions_field_id
  end

  test "commit_breakdown updates description and sets the spec AI action" do
    task = @project.tasks.create!(name: "JW-9 Existing", external_type: "jira", external_reference: "JW-9")
    task.task_drafts.create!(source: TaskDraft::BREAKDOWN_SOURCE,
      content: { needs_breakdown: false, total_points: 3, strategy: "small", subtasks: [] }.to_json)
    c = fake_client
    res = JiraWriter.new(workspace: @workspace, client: c).commit_breakdown(task)
    assert res[:ok], res.inspect
    assert_equal 1, c.calls[:update]
    assert_equal "Added specification and branch", c.calls[:action][:value]
  end

  test "commit_breakdown fails when there is no breakdown" do
    task = @project.tasks.create!(name: "JW-9 Existing", external_type: "jira", external_reference: "JW-9")
    res = JiraWriter.new(workspace: @workspace, client: fake_client).commit_breakdown(task)
    assert_not res[:ok]
  end
end
