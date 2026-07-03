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
end
