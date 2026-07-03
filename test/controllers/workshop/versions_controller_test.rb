require "test_helper"

class Workshop::VersionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    workspaces(:one).update!(workshop_enabled: true)
    sign_in_as(users(:one)) # admin/owner
    post switch_product_path, params: { product: "workshop" }
  end

  def stub_writer(result)
    orig = JiraWriter.instance_method(:commit_brief)
    JiraWriter.define_method(:commit_brief) { |_b| result }
    yield
  ensure
    JiraWriter.define_method(:commit_brief, orig)
  end

  def stub_update_description(&block)
    orig = JiraClient.instance_method(:update_issue_description)
    calls = []
    JiraClient.define_method(:update_issue_description) do |issue_key:, description_text:|
      calls << { issue_key: issue_key, description_text: description_text }
      { ok: true }
    end
    block.call(calls)
  ensure
    JiraClient.define_method(:update_issue_description, orig)
  end

  test "make_current makes the selected brief current exclusively and writes plain text to description (local task)" do
    idea = tasks(:local_task)
    idea.update!(in_pipeline: true, workshop_stage: "briefing", pipeline_entered_at: 1.hour.ago)
    v0 = idea.briefs.create!(workspace: idea.project.workspace, version: 0, origin: "user", status: "draft", content: "v0 text")
    v1 = idea.briefs.create!(workspace: idea.project.workspace, version: 1, origin: "ai", status: "draft", content: "v1 text")
    v1.make_current!

    post make_current_workshop_idea_version_path(idea, v0)

    assert_response :redirect
    assert v0.reload.current?
    refute v1.reload.current?
    assert_equal "v0 text", idea.reload.description
  end

  test "make_current on a Jira-linked task pushes the description via JiraClient" do
    idea = tasks(:jira_task)
    idea.update!(in_pipeline: true, workshop_stage: "briefing", pipeline_entered_at: 1.hour.ago)
    v0 = idea.briefs.create!(workspace: idea.project.workspace, version: 0, origin: "user", status: "draft", content: "v0 text")
    v1 = idea.briefs.create!(workspace: idea.project.workspace, version: 1, origin: "ai", status: "draft", content: "v1 text")
    v1.make_current!

    stub_update_description do |calls|
      post make_current_workshop_idea_version_path(idea, v0)
      assert_equal 1, calls.size
      assert_equal idea.external_reference, calls.first[:issue_key]
      assert_equal "v0 text", calls.first[:description_text]
    end

    assert_response :redirect
    assert v0.reload.current?
  end

  test "make_current sets a toast" do
    idea = tasks(:local_task)
    idea.update!(in_pipeline: true, workshop_stage: "briefing", pipeline_entered_at: 1.hour.ago)
    v0 = idea.briefs.create!(workspace: idea.project.workspace, version: 0, origin: "user", status: "draft", content: "v0 text").tap(&:make_current!)
    v1 = idea.briefs.create!(workspace: idea.project.workspace, version: 1, origin: "ai", status: "draft", content: "v1 text")

    post make_current_workshop_idea_version_path(idea, v1)

    assert_match(/v1 set as current/, flash[:clar_toast])
    assert_match(/local description updated/, flash[:clar_toast])
  end

  # Details stage: the same route/action also accepts a TaskDraft id (source
  # "ai") — the document panel's chips post here regardless of stage. This
  # does NOT touch tasks.description (that column is briefing's; details
  # drafts are separate) and, for a Jira-linked idea, pushes via JiraClient
  # exactly like the brief path.
  test "make_current makes the selected AI draft current exclusively (local task)" do
    idea = tasks(:local_task)
    idea.update!(in_pipeline: true, workshop_stage: "details", pipeline_entered_at: 1.hour.ago)
    v0 = idea.task_drafts.create!(source: "ai", origin: "user", version: 0, content: "v0 detail")
    v1 = idea.task_drafts.create!(source: "ai", origin: "ai", version: 1, content: "v1 detail")
    v1.make_current!

    post make_current_workshop_idea_version_path(idea, v0)

    assert_response :redirect
    assert v0.reload.current?
    refute v1.reload.current?
    assert_nil idea.reload.description, "details set-current must not overwrite tasks.description"
  end

  test "make_current on a Jira-linked task pushes the AI draft's content via JiraClient" do
    idea = tasks(:jira_task)
    idea.update!(in_pipeline: true, workshop_stage: "details", pipeline_entered_at: 1.hour.ago)
    v0 = idea.task_drafts.create!(source: "ai", origin: "user", version: 0, content: "v0 detail")
    v1 = idea.task_drafts.create!(source: "ai", origin: "ai", version: 1, content: "v1 detail")
    v1.make_current!

    stub_update_description do |calls|
      post make_current_workshop_idea_version_path(idea, v0)
      assert_equal 1, calls.size
      assert_equal idea.external_reference, calls.first[:issue_key]
      assert_equal "v0 detail", calls.first[:description_text]
    end

    assert_response :redirect
    assert v0.reload.current?
  end

  test "make_current for an AI draft sets a toast" do
    idea = tasks(:local_task)
    idea.update!(in_pipeline: true, workshop_stage: "details", pipeline_entered_at: 1.hour.ago)
    v0 = idea.task_drafts.create!(source: "ai", origin: "user", version: 0, content: "v0 detail").tap(&:make_current!)
    v1 = idea.task_drafts.create!(source: "ai", origin: "ai", version: 1, content: "v1 detail")

    post make_current_workshop_idea_version_path(idea, v1)

    assert_match(/v1 set as current/, flash[:clar_toast])
  end

  # --- Task 5.2: rich-text editing (create = save-as-new, update = save-in-place) ---

  test "create (save-as-new) for a brief adds a manual-origin version and makes it current" do
    idea = tasks(:local_task)
    idea.update!(in_pipeline: true, workshop_stage: "briefing", pipeline_entered_at: 1.hour.ago)
    v0 = idea.briefs.create!(workspace: idea.project.workspace, version: 0, origin: "user", status: "draft", content: "v0 text").tap(&:make_current!)

    post workshop_idea_versions_path(idea), params: { kind: "brief", content_html: "<p>New <b>rich</b> content</p>" }

    assert_response :redirect
    refute v0.reload.current?
    new_brief = idea.briefs.newest_first.first
    assert_equal "manual", new_brief.origin
    assert_equal 1, new_brief.version
    assert new_brief.current?
    assert_equal "<p>New <b>rich</b> content</p>", new_brief.content
    assert_match(/Saved as new version.*now current/, flash[:clar_toast])
  end

  test "create (save-as-new) for a detail draft adds a manual-origin version and makes it current" do
    idea = tasks(:local_task)
    idea.update!(in_pipeline: true, workshop_stage: "details", pipeline_entered_at: 1.hour.ago)
    v0 = idea.task_drafts.create!(source: "ai", origin: "user", version: 0, content: "v0 detail").tap(&:make_current!)

    post workshop_idea_versions_path(idea), params: { kind: "detail", content_html: "<p>New draft</p>" }

    assert_response :redirect
    refute v0.reload.current?
    new_draft = idea.task_drafts.by_source("ai").newest_first.first
    assert_equal "manual", new_draft.origin
    assert_equal 1, new_draft.version
    assert new_draft.current?
    assert_equal "<p>New draft</p>", new_draft.content
    assert_match(/Saved as new version.*now current/, flash[:clar_toast])
  end

  test "update (save-in-place) for a brief updates content and stamps edited_at without changing version/current/origin" do
    idea = tasks(:local_task)
    idea.update!(in_pipeline: true, workshop_stage: "briefing", pipeline_entered_at: 1.hour.ago)
    v0 = idea.briefs.create!(workspace: idea.project.workspace, version: 0, origin: "user", status: "draft", content: "v0 text").tap(&:make_current!)

    patch workshop_idea_version_path(idea, v0), params: { kind: "brief", content_html: "<p>Edited text</p>" }

    assert_response :redirect
    v0.reload
    assert_equal "<p>Edited text</p>", v0.content
    assert_not_nil v0.edited_at
    assert_equal "user", v0.origin
    assert_equal 0, v0.version
    assert v0.current?
    assert_equal "User description (edited)", v0.label
    assert_match(/Saved v0/, flash[:clar_toast])
  end

  test "update (save-in-place) for a detail draft updates content and stamps edited_at" do
    idea = tasks(:local_task)
    idea.update!(in_pipeline: true, workshop_stage: "details", pipeline_entered_at: 1.hour.ago)
    v1 = idea.task_drafts.create!(source: "ai", origin: "ai", version: 1, content: "v1 detail").tap(&:make_current!)

    patch workshop_idea_version_path(idea, v1), params: { kind: "detail", content_html: "<p>Edited detail</p>" }

    assert_response :redirect
    v1.reload
    assert_equal "<p>Edited detail</p>", v1.content
    assert_not_nil v1.edited_at
    assert_equal "ai", v1.origin
    assert_equal 1, v1.version
    assert v1.current?
    assert_match(/Saved v1/, flash[:clar_toast])
  end

  test "sanitize allowlist strips scripts and event-handler attributes from stored HTML content" do
    idea = tasks(:local_task)
    idea.update!(in_pipeline: true, workshop_stage: "briefing", pipeline_entered_at: 1.hour.ago)
    v0 = idea.briefs.create!(workspace: idea.project.workspace, version: 0, origin: "user", status: "draft", content: "v0 text").tap(&:make_current!)

    malicious = '<p>Hello<script>alert(1)</script></p><img src="x" onerror="alert(2)">'
    patch workshop_idea_version_path(idea, v0), params: { kind: "brief", content_html: malicious }
    v0.reload

    # ApplicationController's sanitize helper (allowlist from the brief) is applied on RENDER,
    # not necessarily on storage — verify the render-time sanitize call strips both vectors.
    sanitized = ActionController::Base.helpers.sanitize(
      v0.content, tags: %w[h4 p b strong i em ul ol li pre code a br], attributes: %w[href]
    )
    assert_no_match(/<script/i, sanitized)
    assert_no_match(/onerror/i, sanitized)
    assert_match(/Hello/, sanitized)
  end
end
