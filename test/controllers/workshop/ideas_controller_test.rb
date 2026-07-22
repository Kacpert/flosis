require "test_helper"

class Workshop::IdeasControllerTest < ActionDispatch::IntegrationTest
  setup do
    workspaces(:one).update!(workshop_enabled: true)
    sign_in_as(users(:one)) # admin/owner
    post switch_product_path, params: { product: "workshop" }
  end

  test "posting a title creates a local pipeline task at briefing and redirects to the idea" do
    assert_difference -> { Task.count }, 1 do
      post workshop_ideas_path, params: { idea: { title: "Aggregated CSV export", description: "" } }
    end

    task = Task.order(:id).last
    assert_equal "Aggregated CSV export", task.name
    assert_equal tasks(:jira_task).project_id, task.project_id
    assert task.in_pipeline?
    assert_equal "briefing", task.workshop_stage
    assert_not_nil task.pipeline_entered_at
    assert_equal users(:one), task.pipeline_author

    assert_redirected_to workshop_idea_path(task)
  end

  test "description present seeds a current v0 user draft brief" do
    post workshop_ideas_path, params: { idea: { title: "Idea with description", description: "A sentence or two." } }

    task = Task.order(:id).last
    brief = task.briefs.find_by(version: 0)
    assert_not_nil brief
    assert brief.current?
    assert_equal "user", brief.origin
    assert_equal "draft", brief.status
    assert_equal "A sentence or two.", brief.content
  end

  test "no description means no brief is seeded" do
    post workshop_ideas_path, params: { idea: { title: "Idea without description", description: "" } }

    task = Task.order(:id).last
    assert_equal 0, task.briefs.count
  end

  test "blank title is unprocessable, not a server error" do
    assert_no_difference -> { Task.count } do
      post workshop_ideas_path, params: { idea: { title: "", description: "" } }
    end

    assert_response :unprocessable_entity
  end

  test "duplicate title in the same project is unprocessable, not a server error" do
    existing = tasks(:jira_task)

    assert_no_difference -> { Task.count } do
      post workshop_ideas_path, params: { idea: { title: existing.name, description: "" } }
    end

    assert_response :unprocessable_entity
  end

  test "POST estimate enqueues AutoEstimateJob for the task and redirects with a toast" do
    task = tasks(:jira_task)

    assert_enqueued_with(job: AutoEstimateJob, args: [ task.id ]) do
      post estimate_workshop_idea_path(task)
    end

    assert_redirected_to workshop_idea_path(task)
    assert_equal "Estimating…", flash[:clar_toast]
  end

  test "POST estimate is scoped to the current workshop project (cross-project 404s)" do
    other = tasks(:secret_task)

    assert_no_enqueued_jobs(only: AutoEstimateJob) do
      post estimate_workshop_idea_path(other)
    end

    assert_response :not_found
  end

  test "importing a task from another project is rejected (not scoped to the workshop project)" do
    # secret_task lives in other_jira_project, outside current_workshop_project's
    # scope, so import must not reach it — the lookup 404s rather than leaking it
    # into this project's pipeline.
    other = tasks(:secret_task)

    # In integration tests the RecordNotFound is caught by the exception
    # middleware and rendered as a 404 rather than propagating to the test.
    post workshop_ideas_path, params: { task_id: other.id }
    assert_response :not_found
    refute other.reload.in_pipeline, "cross-project task must not enter the pipeline"
  end

  test "GET show renders the workspace shell with the stepper at the idea's stage" do
    idea = tasks(:jira_task)
    idea.update!(in_pipeline: true, workshop_stage: "briefing", pipeline_entered_at: 1.hour.ago)

    get workshop_idea_path(idea)

    assert_response :success
    assert_select "h1", idea.name
    assert_select ".clar-key", idea.external_reference
    assert_select "[data-stepper-stage='briefing'][data-stepper-current='true']"

    # The full-screen ("make it bigger") toggle must be wired: the grid carries
    # the clar-focus controller + grid/chat targets, and the header button
    # dispatches to it. Regression guard — the button previously had only an
    # inert data-clar-focus-toggle attribute and did nothing.
    assert_select "[data-controller~='clar-focus'][data-clar-focus-target='grid']"
    assert_select "[data-clar-focus-target='chat']"
    assert_select "button[data-action='click->clar-focus#toggle']"
  end

  test "GET show at briefing stage renders the Clar chat panel wired to the brief_chat routes" do
    idea = tasks(:jira_task)
    idea.update!(in_pipeline: true, workshop_stage: "briefing", pipeline_entered_at: 1.hour.ago)

    get workshop_idea_path(idea, stage: "briefing")

    assert_response :success
    assert_select "[data-controller='clar-chat']" do
      assert_select "[data-clar-chat-create-url-value='#{jira_task_brief_chat_session_path(idea)}']"
      assert_select "[data-clar-chat-message-url-value='#{message_jira_task_brief_chat_session_path(idea)}']"
      assert_select "[data-clar-chat-persona-value='briefing']"
      assert_select "[data-clar-chat-target='messages']"
      assert_select "[data-clar-chat-target='input']"
    end
    assert_select "span", text: /Briefing/
    assert_select "span", text: /Reads project & task description first/
    assert_select "button", text: /Reset session/
  end

  test "GET show wires the document frame to reload when the chat saves a new version" do
    # Regression: a brief saved mid-conversation didn't appear until a full page
    # refresh, because the clar:document-updated event had no listener. The
    # document turbo-frame must carry the clar-document-refresh controller and a
    # reload URL so the panel re-renders with the newest version.
    idea = tasks(:jira_task)
    idea.update!(in_pipeline: true, workshop_stage: "briefing", pipeline_entered_at: 1.hour.ago)

    get workshop_idea_path(idea, stage: "briefing")

    assert_response :success
    assert_select "turbo-frame#clar-document[data-controller~='clar-document-refresh']" \
      "[data-clar-document-refresh-reload-url-value='#{workshop_idea_path(idea, stage: 'briefing')}']"
  end

  test "stepper: a step the task has reached is clickable even when viewing an earlier stage" do
    # Regression: viewing Briefing on a task that reached Details made the Details
    # step un-clickable, so you couldn't jump forward again. Clickability is based
    # on the task's furthest-reached stage, not the viewed stage.
    idea = tasks(:local_task)
    idea.update!(in_pipeline: true, workshop_stage: "details", pipeline_entered_at: 1.hour.ago)

    get workshop_idea_path(idea, stage: "briefing")
    assert_response :success
    # Details (reached) must be a link even though we're viewing Briefing.
    assert_select "[data-stepper-stage='details'] a[href='#{workshop_idea_path(idea, stage: 'details')}']"
    # Ready (not reached) stays non-clickable.
    assert_select "[data-stepper-stage='ready'] a", count: 0
  end

  test "briefing shows 'Continue to Details' once briefed instead of 'Brief & mark Briefed'" do
    idea = tasks(:local_task)
    idea.update!(in_pipeline: true, workshop_stage: "details", pipeline_entered_at: 1.hour.ago)
    brief = idea.briefs.create!(workspace: idea.project.workspace, version: 0, origin: "user", status: "draft", content: "b")
    brief.make_current!
    brief.mark_briefed!

    get workshop_idea_path(idea, stage: "briefing")
    assert_response :success
    assert_select "a[href='#{workshop_idea_path(idea, stage: 'details')}']", text: /Continue to Details/
    assert_select "button", text: /Brief & mark Briefed/, count: 0
  end

  test "briefing shows 'Brief & mark Briefed' when not yet briefed" do
    idea = tasks(:local_task)
    idea.update!(in_pipeline: true, workshop_stage: "briefing", pipeline_entered_at: 1.hour.ago)
    idea.briefs.create!(workspace: idea.project.workspace, version: 0, origin: "user", status: "draft", content: "b").make_current!

    get workshop_idea_path(idea, stage: "briefing")
    assert_response :success
    assert_select "button", text: /Brief & mark Briefed/
    assert_select "a", text: /Continue to Details/, count: 0
  end

  test "briefing panel has NO 'Save locally' button but details panel does" do
    # Save locally is a confusing no-op in briefing (task is already local); it's
    # only meaningful in details (finish-without-Jira → Ready). Guard both ways.
    idea = tasks(:local_task)
    idea.update!(in_pipeline: true, workshop_stage: "briefing", pipeline_entered_at: 1.hour.ago)
    idea.briefs.create!(workspace: idea.project.workspace, version: 0, origin: "user", status: "draft", content: "desc").tap(&:make_current!)

    get workshop_idea_path(idea, stage: "briefing")
    assert_response :success
    assert_select "form[action='#{save_locally_workshop_idea_path(idea)}']", count: 0

    idea.update!(workshop_stage: "details")
    idea.task_drafts.create!(source: TaskDraft::REFINE_SOURCE, origin: "user", content: "d").tap(&:make_current!)
    get workshop_idea_path(idea, stage: "details")
    assert_response :success
    assert_select "form[action='#{save_locally_workshop_idea_path(idea)}']", count: 1
  end

  test "a non-current, non-v0 version shows a Delete button; current and v0 do not" do
    idea = tasks(:local_task)
    idea.update!(in_pipeline: true, workshop_stage: "briefing", pipeline_entered_at: 1.hour.ago)
    ws = idea.project.workspace
    idea.briefs.create!(workspace: ws, version: 0, origin: "user", status: "draft", content: "v0")
    v1 = idea.briefs.create!(workspace: ws, version: 1, origin: "ai", status: "draft", content: "v1")
    v2 = idea.briefs.create!(workspace: ws, version: 2, origin: "ai", status: "draft", content: "v2").tap(&:make_current!)

    # Viewing v1 (not current, not v0) → a version-delete form is present.
    get workshop_idea_path(idea, stage: "briefing", v: 1)
    assert_select "form[action='#{workshop_idea_version_path(idea, v1)}'][method='post'] input[name='_method'][value='delete']", count: 1

    # Viewing v0 (original) → no version-delete form.
    get workshop_idea_path(idea, stage: "briefing", v: 0)
    assert_select "form[action='#{workshop_idea_version_path(idea, idea.briefs.find_by(version: 0))}'] input[name='_method'][value='delete']", count: 0

    # Viewing v2 (current) → no version-delete form.
    get workshop_idea_path(idea, stage: "briefing", v: 2)
    assert_select "form[action='#{workshop_idea_version_path(idea, v2)}'] input[name='_method'][value='delete']", count: 0
  end

  test "GET show at details stage renders the Clar chat panel wired to the refine chat routes" do
    idea = tasks(:jira_task)
    idea.update!(in_pipeline: true, workshop_stage: "details", pipeline_entered_at: 1.hour.ago)

    get workshop_idea_path(idea, stage: "details")

    assert_response :success
    assert_select "[data-controller='clar-chat']" do
      assert_select "[data-clar-chat-create-url-value='#{jira_task_chat_session_path(idea)}']"
      assert_select "[data-clar-chat-message-url-value='#{message_jira_task_chat_session_path(idea)}']"
      assert_select "[data-clar-chat-persona-value='details']"
    end
    assert_select "span", text: /Details Gathering/
    assert_select "span", text: /senior partner/
  end

  test "GET show at briefing stage does not render the details chat panel routes" do
    idea = tasks(:jira_task)
    idea.update!(in_pipeline: true, workshop_stage: "briefing", pipeline_entered_at: 1.hour.ago)

    get workshop_idea_path(idea, stage: "briefing")

    assert_response :success
    assert_select "[data-clar-chat-persona-value='details']", count: 0
  end

  test "GET show at details stage seeds a v0 user-description draft when there are no ai drafts yet" do
    idea = tasks(:jira_task)
    idea.update!(in_pipeline: true, workshop_stage: "details", pipeline_entered_at: 1.hour.ago,
                 description: "The Jira description text")

    assert_difference -> { idea.task_drafts.count }, 1 do
      get workshop_idea_path(idea, stage: "details")
    end

    draft = idea.task_drafts.by_source("ai").current.first
    assert_not_nil draft
    assert_equal 0, draft.version
    assert_equal "user", draft.origin
    assert_equal "The Jira description text", draft.content
  end

  test "GET show at details stage does not reseed when an ai draft already exists" do
    idea = tasks(:jira_task)
    idea.update!(in_pipeline: true, workshop_stage: "details", pipeline_entered_at: 1.hour.ago,
                 description: "The Jira description text")
    idea.task_drafts.create!(source: "ai", origin: "ai", content: "Already drafted").make_current!

    assert_no_difference -> { idea.task_drafts.count } do
      get workshop_idea_path(idea, stage: "details")
    end
  end

  test "GET show at details stage does not seed when the task has no description" do
    idea = tasks(:local_task)
    idea.update!(in_pipeline: true, workshop_stage: "details", pipeline_entered_at: 1.hour.ago, description: "")

    assert_no_difference -> { idea.task_drafts.count } do
      get workshop_idea_path(idea, stage: "details")
    end
  end

  test "details stage shows an always-visible 'Create Jira Ticket' for a local (non-Jira) idea" do
    # A local idea at Details can push: commit_detail creates the Jira issue. The
    # sync_jira button is always visible and enabled, labelled "Create Jira Ticket".
    idea = tasks(:local_task)
    idea.update!(in_pipeline: true, workshop_stage: "details", pipeline_entered_at: 1.hour.ago, external_reference: nil)
    idea.task_drafts.create!(source: TaskDraft::REFINE_SOURCE, origin: "ai", content: "detail draft").make_current!

    get workshop_idea_path(idea, stage: "details")

    assert_response :success
    assert_select "form[action='#{sync_jira_workshop_idea_path(idea, stage: 'details')}'] button:not([disabled])", text: /Create Jira Ticket/
  end

  test "details stage shows 'Update Jira Ticket' for a Jira-linked idea, LOCKED when nothing changed" do
    idea = tasks(:jira_task)
    idea.update!(in_pipeline: true, workshop_stage: "details", pipeline_entered_at: 1.hour.ago)
    # A current draft that has NOT been pushed → Update is enabled.
    draft = idea.task_drafts.create!(source: TaskDraft::REFINE_SOURCE, origin: "ai", content: "detail draft")
    draft.make_current!

    get workshop_idea_path(idea, stage: "details")
    assert_response :success
    assert_select "form[action='#{sync_jira_workshop_idea_path(idea, stage: 'details')}'] button:not([disabled])", text: /Update Jira Ticket/

    # Once pushed (in Jira, nothing new) → Update is LOCKED (disabled).
    draft.update!(pushed_at: Time.current)
    get workshop_idea_path(idea, stage: "details")
    assert_response :success
    assert_select "form[action='#{sync_jira_workshop_idea_path(idea, stage: 'details')}']", count: 0
    assert_select "button[disabled]", text: /Update Jira Ticket/
  end

  test "GET show at details stage renders the Brief history button and read-only modal when briefs exist" do
    idea = tasks(:jira_task)
    idea.update!(in_pipeline: true, workshop_stage: "details", pipeline_entered_at: 1.hour.ago,
                 description: "Jira idea description")
    idea.briefs.create!(workspace: idea.project.workspace, version: 1, origin: "ai", status: "briefed",
                        content: "The historical brief content").make_current!

    get workshop_idea_path(idea, stage: "details")

    assert_response :success
    assert_select "button", text: /Brief history/
    assert_select "[data-clar-modal-panel-id-value='brief-history']" do
      assert_select "h2", text: /Briefing history/
      assert_select "*", text: /The historical brief content/
      assert_select "a[href='#{workshop_idea_path(idea, stage: "briefing")}']", text: /Back to briefing to improve/
    end
  end

  test "GET show at details stage does not render the Brief history button when there are no briefs" do
    idea = tasks(:local_task)
    idea.update!(in_pipeline: true, workshop_stage: "details", pipeline_entered_at: 1.hour.ago,
                 description: "Local idea description")

    get workshop_idea_path(idea, stage: "details")

    assert_response :success
    assert_select "button", text: /Brief history/, count: 0
  end

  test "PATCH update renames a local task and sets a toast" do
    idea = tasks(:local_task)
    idea.update!(in_pipeline: true, workshop_stage: "briefing", pipeline_entered_at: 1.hour.ago)

    patch workshop_idea_path(idea), params: { idea: { name: "New name" } }

    assert_response :success
    assert_equal "New name", idea.reload.name
  end

  test "POST advance with a legal transition sets workshop_stage" do
    idea = tasks(:jira_task)
    idea.update!(in_pipeline: true, workshop_stage: "briefing", pipeline_entered_at: 1.hour.ago)

    post advance_workshop_idea_path(idea), params: { to: "details" }

    assert_response :redirect
    assert_equal "details", idea.reload.workshop_stage
  end

  test "POST advance with an illegal transition is rejected" do
    idea = tasks(:jira_task)
    idea.update!(in_pipeline: true, workshop_stage: "new", pipeline_entered_at: 1.hour.ago)

    post advance_workshop_idea_path(idea), params: { to: "ready" }

    assert_response :unprocessable_entity
    assert_equal "new", idea.reload.workshop_stage
  end

  test "POST save_locally stamps brief_saved_locally_at, sets a toast, and keeps the briefing stage" do
    idea = tasks(:local_task)
    idea.update!(in_pipeline: true, workshop_stage: "briefing", pipeline_entered_at: 1.hour.ago)

    post save_locally_workshop_idea_path(idea)

    assert_response :redirect
    assert_not_nil idea.reload.brief_saved_locally_at
    assert_equal "briefing", idea.workshop_stage
    assert_equal "Brief saved to the task locally · not pushed", flash[:clar_toast]
  end

  def stub_commit_brief(result)
    orig = JiraWriter.instance_method(:commit_brief)
    JiraWriter.define_method(:commit_brief) { |_b| result }
    yield
  ensure
    JiraWriter.define_method(:commit_brief, orig)
  end

  test "POST push_jira at briefing marks the brief briefed and advances to details WITHOUT pushing to Jira" do
    idea = tasks(:local_task)
    idea.update!(in_pipeline: true, workshop_stage: "briefing", pipeline_entered_at: 1.hour.ago)
    brief = idea.briefs.create!(workspace: idea.project.workspace, version: 0, origin: "user", status: "draft",
                                content: "the brief")
    brief.make_current!

    # The Jira write must NOT be called at the briefing step — Jira happens at Details.
    jira_called = false
    orig = JiraWriter.instance_method(:commit_brief)
    JiraWriter.define_method(:commit_brief) { |_b| jira_called = true; { ok: true } }
    begin
      post push_jira_workshop_idea_path(idea)
    ensure
      JiraWriter.define_method(:commit_brief, orig)
    end

    assert_not jira_called, "briefing → details must not push to Jira"
    assert_response :redirect
    idea.reload
    assert_equal "details", idea.workshop_stage
    assert brief.reload.briefed?, "the brief must be marked briefed"
    assert_equal "Briefed · moved to Details", flash[:clar_toast]
  end

  test "POST push_jira at briefing with no brief stays put and warns" do
    idea = tasks(:local_task)
    idea.update!(in_pipeline: true, workshop_stage: "briefing", pipeline_entered_at: 1.hour.ago)

    post push_jira_workshop_idea_path(idea)

    assert_equal "briefing", idea.reload.workshop_stage
    assert_match(/Draft a brief first/, flash[:alert])
  end

  test "POST push_jira at DETAILS pushes to Jira and advances to ready" do
    idea = tasks(:jira_task)
    idea.update!(in_pipeline: true, workshop_stage: "details", pipeline_entered_at: 1.hour.ago)
    idea.task_drafts.create!(source: "ai", origin: "ai", content: "the detailed description").make_current!

    called = false
    orig = JiraWriter.instance_method(:commit_detail)
    JiraWriter.define_method(:commit_detail) { |_d| called = true; { ok: true } }
    begin
      post push_jira_workshop_idea_path(idea)
    ensure
      JiraWriter.define_method(:commit_detail, orig)
    end

    assert called, "the details step must push to Jira"
    assert_equal "ready", idea.reload.workshop_stage
  end

  test "POST sync_jira at BRIEFING creates/updates the Jira ticket WITHOUT advancing the stage" do
    idea = tasks(:local_task)
    idea.update!(in_pipeline: true, workshop_stage: "briefing", pipeline_entered_at: 1.hour.ago)
    idea.briefs.create!(workspace: idea.project.workspace, version: 0, origin: "user", status: "draft", content: "b").make_current!

    called = false
    orig = JiraWriter.instance_method(:commit_brief)
    JiraWriter.define_method(:commit_brief) { |_b| called = true; { ok: true, key: "NEW-9" } }
    begin
      post sync_jira_workshop_idea_path(idea, stage: "briefing")
    ensure
      JiraWriter.define_method(:commit_brief, orig)
    end

    assert called, "sync_jira must push to Jira"
    assert_response :redirect
    assert_equal "briefing", idea.reload.workshop_stage, "sync must NOT advance the stage"
  end

  test "POST sync_jira at DETAILS pushes the detail draft without advancing" do
    idea = tasks(:jira_task)
    idea.update!(in_pipeline: true, workshop_stage: "details", pipeline_entered_at: 1.hour.ago)
    idea.task_drafts.create!(source: TaskDraft::REFINE_SOURCE, origin: "ai", content: "d").make_current!

    stub_commit_detail({ ok: true }) do
      post sync_jira_workshop_idea_path(idea, stage: "details")
    end

    assert_response :redirect
    assert_equal "details", idea.reload.workshop_stage
  end

  test "POST push_jira at DETAILS on a LOCAL idea creates the issue via commit_detail and advances to ready" do
    idea = tasks(:local_task)
    idea.update!(in_pipeline: true, workshop_stage: "details", pipeline_entered_at: 1.hour.ago, external_reference: nil)
    idea.task_drafts.create!(source: "ai", origin: "ai", content: "the detailed description").make_current!

    # commit_detail now handles issue creation for a local idea; stub it ok.
    stub_commit_detail({ ok: true, key: "NEW-1" }) do
      post push_jira_workshop_idea_path(idea)
    end

    assert_response :redirect
    assert_equal "ready", idea.reload.workshop_stage
  end

  test "POST save_locally at details stamps detail_saved_locally_at, advances to ready, and sets a toast" do
    idea = tasks(:jira_task)
    idea.update!(in_pipeline: true, workshop_stage: "details", pipeline_entered_at: 1.hour.ago)
    idea.task_drafts.create!(source: "ai", origin: "ai", content: "the detailed description").make_current!

    post save_locally_workshop_idea_path(idea)

    assert_response :redirect
    idea.reload
    assert_not_nil idea.detail_saved_locally_at
    assert_equal "ready", idea.workshop_stage
    assert_equal "Saved to the task locally · finished without Jira", flash[:clar_toast]
  end

  test "POST save_locally at briefing does not touch detail_saved_locally_at" do
    idea = tasks(:local_task)
    idea.update!(in_pipeline: true, workshop_stage: "briefing", pipeline_entered_at: 1.hour.ago)

    post save_locally_workshop_idea_path(idea)

    assert_nil idea.reload.detail_saved_locally_at
    assert_equal "briefing", idea.workshop_stage
  end

  def stub_commit_detail(result)
    orig = JiraWriter.instance_method(:commit_detail)
    JiraWriter.define_method(:commit_detail) { |_d| result }
    yield
  ensure
    JiraWriter.define_method(:commit_detail, orig)
  end

  test "POST push_jira at details on success clears detail_saved_locally_at, advances to ready, and sets a toast" do
    idea = tasks(:jira_task)
    idea.update!(in_pipeline: true, workshop_stage: "details", pipeline_entered_at: 1.hour.ago,
                 detail_saved_locally_at: 1.minute.ago)
    idea.task_drafts.create!(source: "ai", origin: "ai", content: "the detailed description").make_current!

    stub_commit_detail({ ok: true }) do
      post push_jira_workshop_idea_path(idea)
    end

    assert_response :redirect
    idea.reload
    assert_nil idea.detail_saved_locally_at
    assert_equal "ready", idea.workshop_stage
    assert_equal "Description sent to Jira · marked Detailed", flash[:clar_toast]
  end

  test "POST push_jira at details on failure stays at details and surfaces the error" do
    idea = tasks(:jira_task)
    idea.update!(in_pipeline: true, workshop_stage: "details", pipeline_entered_at: 1.hour.ago)
    idea.task_drafts.create!(source: "ai", origin: "ai", content: "the detailed description").make_current!

    stub_commit_detail({ ok: false, error: "403 Forbidden" }) do
      post push_jira_workshop_idea_path(idea)
    end

    assert_equal "details", idea.reload.workshop_stage
    follow_redirect!
    assert_match "403", response.body
  end

  test "POST push_jira at ready pushes without regressing the stage back to details" do
    # A local idea that finished via Save locally reaches Ready with no Jira
    # issue. Pushing from the Ready screen creates the issue but must KEEP the
    # idea at "ready" (not fall through to the briefing branch's ->details bump).
    idea = tasks(:local_task)
    idea.update!(in_pipeline: true, workshop_stage: "ready", pipeline_entered_at: 1.hour.ago,
                 brief_saved_locally_at: 1.minute.ago)
    idea.briefs.create!(workspace: idea.project.workspace, version: 0, origin: "user", status: "draft",
                        content: "the brief").make_current!

    stub_commit_brief({ ok: true, key: "ELV-9", url: "https://example.com/ELV-9" }) do
      post push_jira_workshop_idea_path(idea)
    end

    idea.reload
    assert_equal "ready", idea.workshop_stage, "push at ready must not regress to details"
    assert_nil idea.brief_saved_locally_at
    assert_equal "Pushed to Jira", flash[:clar_toast]
  end

  test "POST push_jira at briefing still uses the briefing branch (existing behavior unaffected)" do
    idea = tasks(:local_task)
    idea.update!(in_pipeline: true, workshop_stage: "briefing", pipeline_entered_at: 1.hour.ago)
    idea.briefs.create!(workspace: idea.project.workspace, version: 0, origin: "user", status: "draft",
                        content: "the brief").make_current!

    stub_commit_brief({ ok: true, key: "ELV-9", url: "https://example.com/ELV-9" }) do
      post push_jira_workshop_idea_path(idea)
    end

    assert_equal "details", idea.reload.workshop_stage
  end

  test "GET show at ready stage renders the Ready screen with the summary and branch cards" do
    idea = tasks(:jira_task)
    idea.update!(in_pipeline: true, workshop_stage: "ready", pipeline_entered_at: 1.hour.ago,
                 detail_saved_locally_at: nil)
    idea.task_drafts.create!(source: "ai", origin: "ai", content: "the detailed description",
                             pushed_at: 1.minute.ago).make_current!
    idea.task_drafts.create!(source: "breakdown", origin: "ai",
                             content: { total_points: 8, needs_breakdown: false, subtasks: [] }.to_json)

    get workshop_idea_path(idea, stage: "ready")

    assert_response :success
    assert_select "h2", text: /Ready for the team/
    assert_select "*", text: /#{idea.external_reference}/
    assert_select "*", text: idea.name
    assert_select "*", text: /IN JIRA/
    assert_select "*", text: /Detailed/
    assert_select "*", text: /8 pts/
    assert_select "*", text: /auto/
    assert_select "code", text: idea.suggested_branch
    assert_select "*", text: /AI prepared a branch/
  end

  test "GET show at ready stage shows Push to Jira when the detail draft has not been pushed" do
    idea = tasks(:jira_task)
    idea.update!(in_pipeline: true, workshop_stage: "ready", pipeline_entered_at: 1.hour.ago)
    idea.task_drafts.create!(source: "ai", origin: "ai", content: "the detailed description",
                             pushed_at: nil).make_current!

    get workshop_idea_path(idea, stage: "ready")

    assert_response :success
    assert_select "form[action='#{push_jira_workshop_idea_path(idea)}']" do
      assert_select "button", text: /Push to Jira/
    end
  end

  test "GET show at ready stage hides Push to Jira once the detail draft is pushed" do
    idea = tasks(:jira_task)
    idea.update!(in_pipeline: true, workshop_stage: "ready", pipeline_entered_at: 1.hour.ago)
    idea.task_drafts.create!(source: "ai", origin: "ai", content: "the detailed description",
                             pushed_at: 1.minute.ago).make_current!

    get workshop_idea_path(idea, stage: "ready")

    assert_response :success
    assert_select "button", text: /Push to Jira/, count: 0
  end

  test "GET show at ready stage renders Detailed vs Briefed vs em-dash for AI actions" do
    idea = tasks(:jira_task)
    idea.update!(in_pipeline: true, workshop_stage: "ready", pipeline_entered_at: 1.hour.ago)

    get workshop_idea_path(idea, stage: "ready")
    assert_response :success
    assert_select "*", text: "—" # em-dash: no brief, no pushed detail

    idea.briefs.create!(workspace: idea.project.workspace, version: 1, origin: "ai", status: "briefed",
                        content: "briefed content").make_current!
    get workshop_idea_path(idea, stage: "ready")
    assert_select "*", text: /Briefed/
  end

  test "GET show at ready stage shows an em-dash for AI estimation when there is no breakdown" do
    idea = tasks(:local_task)
    idea.update!(in_pipeline: true, workshop_stage: "ready", pipeline_entered_at: 1.hour.ago)

    get workshop_idea_path(idea, stage: "ready")

    assert_response :success
    assert_select "*", text: "—"
  end

  test "GET show at ready stage renders Back to pipeline" do
    idea = tasks(:local_task)
    idea.update!(in_pipeline: true, workshop_stage: "ready", pipeline_entered_at: 1.hour.ago)

    get workshop_idea_path(idea, stage: "ready")

    assert_response :success
    assert_select "a[href='#{workshop_pipeline_path}']", text: /Back to pipeline/
  end
end
