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

  test "commit_detail updates the description, sets the Detailed AI action, and stamps pushed_at" do
    task = @project.tasks.create!(name: "JW-11 Existing", external_type: "jira", external_reference: "JW-11")
    draft = task.task_drafts.create!(source: TaskDraft::REFINE_SOURCE, origin: "ai", content: "detailed text")
    c = fake_client
    res = JiraWriter.new(workspace: @workspace, client: c).commit_detail(draft)

    assert res[:ok], res.inspect
    assert_equal 1, c.calls[:update]
    assert_equal "Detailed", c.calls[:action][:value]
    assert_equal "JW-11", c.calls[:action][:issue_key]
    assert_not_nil draft.reload.pushed_at
  end

  test "commit_detail fails when the task is not linked to Jira" do
    task = @project.tasks.create!(name: "Local idea")
    draft = task.task_drafts.create!(source: TaskDraft::REFINE_SOURCE, origin: "ai", content: "detailed text")
    res = JiraWriter.new(workspace: @workspace, client: fake_client).commit_detail(draft)

    assert_not res[:ok]
    assert_equal "Task is not linked to Jira", res[:error]
    assert_nil draft.reload.pushed_at
  end

  test "commit_detail returns the error and does not stamp pushed_at when the description update fails" do
    task = @project.tasks.create!(name: "JW-12 Existing", external_type: "jira", external_reference: "JW-12")
    draft = task.task_drafts.create!(source: TaskDraft::REFINE_SOURCE, origin: "ai", content: "detailed text")
    c = fake_client(update: { ok: false, error: "403 Forbidden" })
    res = JiraWriter.new(workspace: @workspace, client: c).commit_detail(draft)

    assert_not res[:ok]
    assert_equal "403 Forbidden", res[:error]
    assert_nil draft.reload.pushed_at
    assert_nil c.calls[:action], "AI action must not be set when the description update failed"
  end

  # --- Task 5.2: HTML-edited briefs/drafts must reach Jira as plain text ---

  # Captures the description_text a JiraClient double receives, so tests can
  # assert on exactly what was pushed (not just that the call happened).
  def capturing_client(create: { ok: true, key: "JW-1", url: "u" }, update: { ok: true }, action: { ok: true })
    c = Object.new
    captured = { create: nil, update: nil, action: nil }
    c.define_singleton_method(:create_issue) { |**k| captured[:create] = k; create }
    c.define_singleton_method(:update_issue_description) { |**k| captured[:update] = k; update }
    c.define_singleton_method(:add_ai_action) { |**k| captured[:action] = k; action }
    c.define_singleton_method(:fetch_field_id) { |_n| "customfield_10050" }
    c.define_singleton_method(:captured) { captured }
    c
  end

  test "commit_brief strips HTML tags before pushing an existing task's description to Jira" do
    task = @project.tasks.create!(name: "JW-20 Existing", external_type: "jira", external_reference: "JW-20")
    html = '<h4>Summary</h4><p>Hello <b>world</b></p><ul><li>One</li><li>Two</li></ul><script>alert(1)</script>'
    brief = Brief.create!(task: task, workspace: @workspace, version: 1, content: html)
    c = capturing_client
    res = JiraWriter.new(workspace: @workspace, client: c).commit_brief(brief)

    assert res[:ok], res.inspect
    text = c.captured[:update][:description_text]
    assert_no_match(/<[^>]+>/, text, "description_text must have no HTML tags: #{text.inspect}")
    assert_no_match(/alert\(1\)/, text, "script contents must not leak into the plain text")
    assert_match(/Summary/, text)
    assert_match(/Hello world/, text)
  end

  test "commit_brief strips HTML tags before creating a new issue's description in Jira" do
    task = @project.tasks.create!(name: "New idea")
    html = "<p>Some <i>rich</i> concept</p>"
    brief = Brief.create!(task: task, workspace: @workspace, version: 1, content: html)
    c = capturing_client
    res = JiraWriter.new(workspace: @workspace, client: c).commit_brief(brief)

    assert res[:ok], res.inspect
    text = c.captured[:create][:description_text]
    assert_no_match(/<[^>]+>/, text)
    assert_match(/Some rich concept/, text)
  end

  test "commit_detail strips HTML tags before pushing the draft's description to Jira" do
    task = @project.tasks.create!(name: "JW-21 Existing", external_type: "jira", external_reference: "JW-21")
    html = "<p>Detailed <strong>plan</strong></p>"
    draft = task.task_drafts.create!(source: TaskDraft::REFINE_SOURCE, origin: "ai", content: html)
    c = capturing_client
    res = JiraWriter.new(workspace: @workspace, client: c).commit_detail(draft)

    assert res[:ok], res.inspect
    text = c.captured[:update][:description_text]
    assert_no_match(/<[^>]+>/, text)
    assert_match(/Detailed plan/, text)
  end

  test "plain-text/markdown content passes through the strip helper unchanged (aside from blank-line squeeze)" do
    task = @project.tasks.create!(name: "JW-22 Existing", external_type: "jira", external_reference: "JW-22")
    markdown = "## Foo\n\nSome plain text with *emphasis* and no tags."
    draft = task.task_drafts.create!(source: TaskDraft::REFINE_SOURCE, origin: "ai", content: markdown)
    c = capturing_client
    res = JiraWriter.new(workspace: @workspace, client: c).commit_detail(draft)

    assert res[:ok], res.inspect
    assert_equal markdown, c.captured[:update][:description_text]
  end
end
