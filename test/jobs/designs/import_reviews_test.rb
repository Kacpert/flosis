require "test_helper"

# Designs imports: an update that would replace a thread's work on master
# never lands by itself. It waits as a review card, showing what comes in,
# what is kept and what is replaced; Accept lands it, Reject keeps master as
# it is, and words for the AI make a new proposal on the same branch. The
# sign-in, the app's repositories and Claude are stood in for.
class Designs::ImportReviewsTest < ActionDispatch::IntegrationTest
  include DesignRepoTestHelper
  include ActiveJob::TestHelper

  CARD = "<h1>Bugs</h1>\n<div class=\"card\">old card</div>\n<footer>Assign</footer>\n".freeze

  setup do
    @preview_root = Dir.mktmpdir("preview")
    ENV["DESIGNS_PREVIEW_ROOT"] = @preview_root
    Designs::SetupRunJob.sign_in = ->(_setup) { { "1-admin" => true } }
    Designs::SetupRunJob.app_repos = ->(_setup) { [] }
    Designs::SetupRunJob.killer = ->(_session_id) {}
    workspaces(:one).update!(workshop_enabled: true)
    @project = projects(:jira_project)
    @project.update!(designs_enabled: true)
    sign_in_as(users(:one))
    post switch_product_path, params: { product: "workshop" }
    post switch_workshop_project_path, params: { project_id: @project.id }
  end

  teardown do
    ENV.delete("DESIGNS_PREVIEW_ROOT")
    FileUtils.remove_entry(@preview_root)
    Designs::SetupRunJob.turn_runner = nil
    Designs::SetupRunJob.sign_in = nil
    Designs::SetupRunJob.app_repos = nil
    Designs::SetupRunJob.killer = nil
  end

  # master: Bug Reporting as the import made it, then "Bug card v2", a
  # thread's redesign of its card, merged; and the import, over, with Bug
  # Reporting queued again.
  def with_a_thread_on_master
    with_design_remote(@project) do |repo, remote|
      with_remote_url(remote) do
        repo.ensure_clone!
        commit_files(repo, repo.root, { Designs::Repo::RUNTIME => "// the runtime\n", "designs/admin/bugs.html" => CARD }, message: "setup: Add Bug Reporting")
        repo.push!("master")
        thread = @project.design_threads.create!(title: "Bug card v2", branch: "design/bug-card-v2", author: users(:one))
        commit_files(repo, repo.worktree!(thread.branch, from: "master"), { "designs/admin/bugs.html" => CARD.sub("old card", "new card") },
                     message: "bug-card-v2: redesign the card")
        sha = repo.merge_into_master!(thread.branch, message: "Merge design/bug-card-v2: Bug card v2")
        repo.push!("master")
        @project.design_merges.create!(sha: sha, title: thread.title, branch: thread.branch, how: "manual", design_thread: thread, merged_at: Time.current)
        @project.reload.update!(design_repo_status: "ready")
        @project.design_setup_roles.create!(name: "Admin", login_url: "https://s.test/login", username: "a", password: "p", position: 0)
        @import = @project.design_setups.create!(status: "approved", phase: "feature", step: 6, started_by: users(:one), finished_at: 1.hour.ago, settled_at: 1.hour.ago)
        @feature = @import.features.create!(name: "Bug Reporting", key: "bug-reporting", position: 1, status: "failed", contexts: %w[1-admin],
                                            error: "Failed to parse Claude response")
        yield repo, remote
      end
    end
  end

  # Claude, as an update from the app: the card as the app has it now, and
  # the three lists.
  def fake_update(repo, card: "the app's card")
    @requests = []
    @kinds = []
    lambda do |turn_id|
      turn = DesignTurn.find(turn_id)
      @requests << turn.chat_message.content
      @kinds << turn.kind
      feature = @import.reload.features.find_by!(status: "running")
      dir = repo.worktree!(feature.branch, from: "master")
      if turn.resolve_conflicts?
        GitRunner.run!("reset", "--hard", "refs/heads/master", chdir: dir)
        commit_files(repo, dir, { "designs/admin/bugs.html" => GitRunner.run!("show", "refs/heads/master:designs/admin/bugs.html", chdir: dir).sub("<footer>", "<p>Filter</p>\n<footer>") })
      else
        commit_files(repo, dir, { "designs/admin/bugs.html" => CARD.sub("old card", card) })
      end
      repo.push!(feature.branch, "--force")
      messages = turn.chat_session.chat_messages
      messages.create!(role: "assistant", kind: "summary", content: "Updated Bug Reporting.")
      messages.create!(role: "assistant", kind: "comes_in", content: "The card as the app has it.")
      messages.create!(role: "assistant", kind: "replaced", content: "Your redesigned card from “Bug card v2”.")
      turn.update!(status: "succeeded", commit_sha: repo.head(feature.branch))
    end
  end

  def review_it(repo)
    Designs::SetupRunJob.turn_runner = fake_update(repo)
    @feature.queue!
    perform_enqueued_jobs(only: Designs::SetupRunJob) { @import.start_work! }
    @feature.reload
  end

  def page_path = workshop_designs_overview_path(tab: "imports", import: @import.id)

  test "an update that changes a thread's lines waits for review instead of landing" do
    with_a_thread_on_master do |repo, remote|
      master = remote_branch_sha(remote, "master")
      review_it(repo)

      assert_equal :review, @feature.problem
      assert_equal [ [ "The card as the app has it." ], [], [ "Your redesigned card from “Bug card v2”." ], [ "Bug card v2" ], [ "designs/admin/bugs.html" ] ],
                   @feature.review.values_at("comes_in", "kept", "replaced", "threads", "paths")
      assert_equal master, remote_branch_sha(remote, "master"), "nothing reaches master until he decides"
      assert remote_branch_sha(remote, @feature.branch), "the proposal waits on its own branch"
      assert_equal [ "manual" ], @project.design_merges.pluck(:how)
      assert_includes @requests.sole, "## Work from threads on master\n- “Bug card v2”"
    end
  end

  test "the review card lists what comes in, what is kept and what is replaced" do
    with_a_thread_on_master do |repo, _remote|
      review_it(repo)
      get page_path
      body = CGI.unescapeHTML(response.body)
      assert_includes body, "Review what comes in"
      assert_includes body, "COMES IN"
      assert_includes body, "The card as the app has it."
      assert_includes body, "From “Bug card v2”"
      assert_select "form[action=?]", accept_workshop_design_import_feature_path(@import, @feature)
      assert_select "form[action=?]", reject_workshop_design_import_feature_path(@import, @feature)
      assert_select "form[action=?] textarea[name=words]", revise_workshop_design_import_feature_path(@import, @feature)
      assert_select "form[action=?]", set_aside_workshop_design_import_feature_path(@import, @feature), false
    end
  end

  test "Accept lands it" do
    with_a_thread_on_master do |repo, remote|
      review_it(repo)
      post accept_workshop_design_import_feature_path(@import, @feature)
      assert_redirected_to page_path

      assert_equal [ "done", nil ], [ @feature.reload.status, @feature.branch ]
      assert_equal %w[manual import], @project.design_merges.order(:id).pluck(:how)
      assert_includes GitRunner.run!("show", "master:designs/admin/bugs.html", chdir: remote), "the app's card"
    end
  end

  test "Reject keeps master as it is and sets the card aside" do
    with_a_thread_on_master do |repo, remote|
      master = remote_branch_sha(remote, "master")
      branch = review_it(repo).branch
      post reject_workshop_design_import_feature_path(@import, @feature)

      @feature.reload
      assert_equal [ "set_aside", nil ], [ @feature.status, @feature.branch ]
      assert_equal "Rejected · not brought in: The card as the app has it.", @feature.review["rejected"]
      assert_equal master, remote_branch_sha(remote, "master")
      assert_nil remote_branch_sha(remote, branch)
      assert_nil repo.head(branch)
    end
  end

  test "Tell the AI something first… goes on from the proposal's branch" do
    with_a_thread_on_master do |repo, _remote|
      branch = review_it(repo).branch
      post revise_workshop_design_import_feature_path(@import, @feature), params: { words: "Take the app's card but keep the footer." }
      assert_equal [ "todo", branch, "Take the app's card but keep the footer." ], [ @feature.reload.status, @feature.branch, @feature.reply ]

      perform_enqueued_jobs(only: Designs::SetupRunJob)
      assert_includes @requests.last, "## What they said about your proposal\nTake the app's card but keep the footer."
      assert_equal :review, @feature.reload.problem, "a new proposal, reviewed again"
    end
  end

  test "Accept after master moved the same lines brings the proposal up to date first" do
    with_a_thread_on_master do |repo, remote|
      review_it(repo)
      push_from_elsewhere(remote, "master", { "designs/admin/bugs.html" => CARD.sub("old card", "a newer thread's card") })
      post accept_workshop_design_import_feature_path(@import, @feature)
      assert_equal [ "todo", true ], [ @feature.reload.status, @feature.review["accepted"] ]

      perform_enqueued_jobs(only: Designs::SetupRunJob)
      assert_equal "resolve_conflicts", @kinds.last
      assert_equal "done", @feature.reload.status
      assert_includes GitRunner.run!("show", "master:designs/admin/bugs.html", chdir: remote), "<p>Filter</p>"
    end
  end
end
