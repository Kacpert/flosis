require "test_helper"

# Designs imports: what the person does from an import's page. Retry, words
# for the AI, Send and continue, Not needed and Retry all queue the work and
# start it; only someone with the configuration permission may.
class Workshop::DesignImportActionsTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    workspaces(:one).update!(workshop_enabled: true)
    @project = projects(:jira_project)
    @project.update!(designs_enabled: true, design_repo_status: "ready")
    sign_in_as(users(:one))
    post switch_product_path, params: { product: "workshop" }
    post switch_workshop_project_path, params: { project_id: @project.id }
    @import = @project.design_setups.create!(status: "approved", phase: "feature", step: 6, started_by: users(:one),
                                             finished_at: 1.hour.ago, settled_at: 1.hour.ago)
    @unreadable = feature("Task workspace", "failed", error: "Failed to parse Claude response")
    @limited = feature("Designs", "failed", error: "Claude stopped with an error: You've hit your session limit · resets 8am (Europe/Warsaw)")
    @waiting = feature("Jira Tasks board", "waiting", question: "Connect Jira?", branch: "wip/import-1-jira-tasks-board")
  end

  def feature(name, status, **more)
    @import.features.create!(name: name, key: name.parameterize, position: @import.features.count + 1, status: status, **more)
  end

  def page_path = workshop_designs_overview_path(tab: "imports", import: @import.id)

  test "Retry queues the feature and starts the work" do
    post retry_workshop_design_import_feature_path(@import, @unreadable)
    assert_redirected_to page_path
    assert_equal [ "todo", nil ], [ @unreadable.reload.status, @unreadable.reply ]
    assert_enqueued_with(job: Designs::SetupRunJob, args: [ @import.id ])
  end

  test "Tell the AI something first… goes with the retry" do
    post retry_workshop_design_import_feature_path(@import, @unreadable), params: { words: "Open the Briefing tab first." }
    assert_equal [ "todo", "Open the Briefing tab first." ], [ @unreadable.reload.status, @unreadable.reply ]
  end

  test "Send and continue queues the reply on the feature's branch" do
    post reply_workshop_design_import_feature_path(@import, @waiting), params: { reply: "Connected it, go on." }
    @waiting.reload
    assert_equal [ "todo", "Connected it, go on.", "wip/import-1-jira-tasks-board", "Connect Jira?" ],
                 [ @waiting.status, @waiting.reply, @waiting.branch, @waiting.question ]
    assert_enqueued_with(job: Designs::SetupRunJob, args: [ @import.id ])
  end

  test "an empty reply is refused" do
    post reply_workshop_design_import_feature_path(@import, @waiting), params: { reply: "  " }
    assert_equal "waiting", @waiting.reload.status
    assert_no_enqueued_jobs only: Designs::SetupRunJob
  end

  test "Not needed sets the card aside" do
    post set_aside_workshop_design_import_feature_path(@import, @limited)
    assert_redirected_to page_path
    assert_equal "set_aside", @limited.reload.status
    assert_not_includes @import.needs_you, @limited
  end

  test "Retry all queues every feature that needs you, once" do
    post retry_all_workshop_design_import_path(@import)
    assert_redirected_to page_path
    assert_equal [ "todo", "todo", "waiting" ], [ @unreadable, @limited, @waiting ].map { _1.reload.status }, "a question waits for its answer"
    queued = [ @unreadable.queued_at, @limited.queued_at ]
    assert_enqueued_jobs 1, only: Designs::SetupRunJob

    post retry_all_workshop_design_import_path(@import)
    assert_equal queued, [ @unreadable.reload.queued_at, @limited.reload.queued_at ]
    assert_enqueued_jobs 1, only: Designs::SetupRunJob
  end

  test "the page offers each card's actions" do
    get page_path
    assert_select "form[action=?]", retry_workshop_design_import_feature_path(@import, @unreadable)
    assert_select "form[action=?]", set_aside_workshop_design_import_feature_path(@import, @limited)
    assert_select "form[action=?] textarea[name=reply]", reply_workshop_design_import_feature_path(@import, @waiting)
    assert_select "form[action=?]", retry_all_workshop_design_import_path(@import), text: /Retry all 2/
  end

  test "someone without configuration cannot retry" do
    project_memberships(:two_elvium).update!(designs: true, configuration: false)
    sign_in_as(users(:two))
    post switch_product_path, params: { product: "workshop" }
    post switch_workshop_project_path, params: { project_id: @project.id }

    post retry_workshop_design_import_feature_path(@import, @unreadable)
    assert_equal "failed", @unreadable.reload.status
    assert_no_enqueued_jobs only: Designs::SetupRunJob
  end
end
