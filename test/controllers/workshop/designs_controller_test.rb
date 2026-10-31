require "test_helper"

class Workshop::DesignsControllerTest < ActionDispatch::IntegrationTest
  include DesignRepoTestHelper

  setup do
    @preview_root = Dir.mktmpdir("preview")
    ENV["DESIGNS_PREVIEW_ROOT"] = @preview_root
    @workspace = workspaces(:one)
    @workspace.update!(workshop_enabled: true)
    @project = projects(:jira_project)
    @project.update!(designs_enabled: true, design_repo: "acme/designs", design_repo_token: "dt",
                     design_repo_status: "ready", design_preview_token: "t0k", anthropic_api_key: "sk-ant")
    @idea = tasks(:jira_task)
    @idea.update!(project: @project, external_reference: "REC-1")
    @idea.enter_pipeline!(author: users(:one), stage: "briefing")
    sign_in_as(users(:one))
    post switch_product_path, params: { product: "workshop" }
    post switch_workshop_project_path, params: { project_id: @project.id }
  end

  teardown do
    ENV.delete("DESIGNS_PREVIEW_ROOT")
    FileUtils.remove_entry(@preview_root)
  end

  test "the screen shows the approved top bar, the chat frame and the preview" do
    get workshop_idea_designs_path(@idea)
    assert_response :success
    assert_select "body", /Designs/
    assert_select "body", %r{design/REC-1}
    assert_select "a", /Open in new tab/
    assert_select "button, input[type=submit]", /Approve/
    assert_select "turbo-frame#designs-chat"
    assert_select "iframe[src^=?]", "#{Designs::Publisher.base_url}/t0k/"
  end

  test "a message starts a queued turn" do
    assert_enqueued_with(job: Designs::TurnJob) do
      post message_workshop_idea_designs_path(@idea), params: { content: "Add an archive tab" }
    end
    turn = DesignTurn.last
    assert turn.queued?
    assert_equal "Add an archive tab", turn.chat_message.content
    assert_equal "designs", turn.chat_session.purpose
  end

  test "a second message while a turn runs is queued" do
    post message_workshop_idea_designs_path(@idea), params: { content: "first" }
    DesignTurn.last.start!
    post message_workshop_idea_designs_path(@idea), params: { content: "second" }
    assert_equal %w[running queued], DesignTurn.order(:id).pluck(:status)
    assert_equal 1, ChatSession.where(task: @idea, purpose: "designs").count
  end

  test "a project without its own API key cannot start a turn" do
    @project.update!(anthropic_api_key: nil)
    get workshop_idea_designs_path(@idea)
    assert_select "body", /Configuration › AI/
    assert_no_enqueued_jobs(only: Designs::TurnJob) do
      post message_workshop_idea_designs_path(@idea), params: { content: "hi" }
    end
    assert_response :unprocessable_entity
  end

  test "Designs that are not set up send you back to the idea" do
    @project.update!(design_repo_status: nil)
    get workshop_idea_designs_path(@idea)
    assert_redirected_to workshop_idea_path(@idea)
  end

  test "someone without the Tasks permission is kept out" do
    project_memberships(:two_elvium).update!(PermissionPreset::PERMISSIONS.index_with(false).merge(briefing_config: true))
    sign_out
    sign_in_as(users(:two))
    post switch_product_path, params: { product: "workshop" }
    get workshop_idea_designs_path(@idea)
    assert_response :redirect
  end

  test "the idea header links to Designs only when they are ready" do
    get workshop_idea_path(@idea)
    assert_select "a[href=?]", workshop_idea_designs_path(@idea)
    @project.update!(designs_enabled: false)
    get workshop_idea_path(@idea)
    assert_select "a[href=?]", workshop_idea_designs_path(@idea), count: 0
  end

  test "the chat frame comes alone, and a turn that was cut off is failed first" do
    post message_workshop_idea_designs_path(@idea), params: { content: "first" }
    turn = DesignTurn.last
    turn.start!
    turn.update_columns(started_at: DesignTurn.stale_after.ago - 1.minute)
    get chat_workshop_idea_designs_path(@idea)
    assert_response :success
    assert_select "turbo-frame#designs-chat"
    assert_select "iframe", count: 0
    assert turn.reload.failed?
  end

  # Ruling P2-R7: a turn failed as stale has no error message in the chat.
  test "the latest failed turn can be retried, though the chat holds no error for it" do
    post message_workshop_idea_designs_path(@idea), params: { content: "first" }
    turn = DesignTurn.last
    turn.start!
    turn.update_columns(started_at: DesignTurn.stale_after.ago - 1.minute)
    get workshop_idea_designs_path(@idea)
    assert_select "body", Regexp.new(Regexp.escape(DesignTurn::INTERRUPTED))
    assert_select "form[action=?]", retry_workshop_idea_designs_path(@idea)
    assert_enqueued_with(job: Designs::TurnJob, args: [ turn.id ]) do
      post retry_workshop_idea_designs_path(@idea)
    end
    assert turn.reload.queued?
    assert_nil turn.error
  end

  test "an error in the chat is shown with a way to retry it" do
    post message_workshop_idea_designs_path(@idea), params: { content: "first" }
    turn = DesignTurn.last
    turn.start!
    turn.fail!("Claude stopped with an error: overloaded")
    turn.chat_session.chat_messages.create!(role: "assistant", kind: "error", content: turn.error)
    get workshop_idea_designs_path(@idea)
    assert_select "body", /overloaded/
    assert_select "form[action=?]", retry_workshop_idea_designs_path(@idea), count: 1
  end

  test "before the first turn nothing is waiting and there is nothing to approve" do
    with_design_remote(@project) do |repo, _|
      seed_master(repo)
      get workshop_idea_designs_path(@idea)
      assert_select "body", %r{design/REC-1 · 0 waiting}
      assert_select "form[action=?] button[disabled]", approve_workshop_idea_designs_path(@idea)
    end
  end

  test "work on the branch is counted and can be approved" do
    with_design_remote(@project) do |repo, remote|
      seed_master(repo)
      commit_files(repo, repo.worktree!("wip/REC-1"), { "designs/jobs.html" => "jobs" })
      get workshop_idea_designs_path(@idea)
      assert_select "body", %r{design/REC-1 · 1 waiting}
      assert_select "form[action=?] button:not([disabled])", approve_workshop_idea_designs_path(@idea)

      with_remote_url(remote) { post approve_workshop_idea_designs_path(@idea) }
      assert_redirected_to workshop_idea_designs_path(@idea)
      assert_equal "Approved as version 1.", flash[:clar_toast]

      with_remote_url(remote) { post approve_workshop_idea_designs_path(@idea) }
      assert_equal "Nothing new to approve.", flash[:alert]
    end
  end

  test "work that collides with master is not approved, and the screen offers to update from master" do
    with_design_remote(@project) do |repo, remote|
      seed_master(repo, { "designs/a.html" => "base\n" })
      commit_files(repo, repo.worktree!("wip/REC-1"), { "designs/a.html" => "task\n" })
      commit_files(repo, repo.root, { "designs/a.html" => "master\n" })
      repo.push!("master")
      with_remote_url(remote) { post approve_workshop_idea_designs_path(@idea) }
      assert_equal "Master has changed in the same files. Use “Update from master”, then approve again.", flash[:alert]
      follow_redirect!
      assert_select "form[action=?]", update_from_master_workshop_idea_designs_path(@idea)

      assert_enqueued_with(job: Designs::TurnJob) do
        with_remote_url(remote) { post update_from_master_workshop_idea_designs_path(@idea) }
      end
      assert_equal "Master changed the same files — Claude is resolving the conflicts.", flash[:clar_toast]
      assert_equal "resolve_conflicts", DesignTurn.last.kind
    end
  end

  test "nothing is approved or updated while a turn is active" do
    with_design_remote(@project) do |repo, remote|
      seed_master(repo)
      commit_files(repo, repo.worktree!("wip/REC-1"), { "designs/jobs.html" => "jobs" })
      post message_workshop_idea_designs_path(@idea), params: { content: "more" }
      get workshop_idea_designs_path(@idea)
      assert_select "form[action=?] button[disabled]", approve_workshop_idea_designs_path(@idea)
      with_remote_url(remote) { post approve_workshop_idea_designs_path(@idea) }
      assert_equal "Wait for the current turn to finish, then approve.", flash[:alert]
      with_remote_url(remote) { post update_from_master_workshop_idea_designs_path(@idea) }
      assert_equal "Wait for the current turn to finish, then update from master.", flash[:alert]
    end
  end

  # Ruling P2-R26: a request never waits on the repo's lock.
  test "approving while a job holds the design repo says it is busy" do
    with_design_remote(@project) do |repo, remote|
      seed_master(repo)
      commit_files(repo, repo.worktree!("wip/REC-1"), { "designs/jobs.html" => "jobs" })
      File.open(repo.root.dirname.join("design-repo.lock")) do |job|
        job.flock(File::LOCK_EX)
        Timeout.timeout(10) do
          get workshop_idea_designs_path(@idea)
          assert_select "body", %r{design/REC-1 · 1 waiting}
          with_remote_url(remote) { post approve_workshop_idea_designs_path(@idea) }
        end
      end
      assert_equal "The design repo is busy — try again in a minute.", flash[:alert]
      assert_nil remote_branch_sha(remote, "design/REC-1")
    end
  end

  # Ruling P2-R27: the screen refreshes whole when a turn ends, and the
  # contexts picked survive in its own address.
  test "the contexts named in the page's address are the active ones, and any other falls back to the default" do
    with_design_remote(@project) do |repo, _|
      seed_master(repo)
      repo.root.join("designs").mkpath
      repo.root.join("designs/contexts.json").write(JSON.generate(
        "dimensions" => [
          { "id" => "role", "name" => "Role", "default" => "full",
            "values" => [ { "id" => "full", "name" => "Full access" }, { "id" => "viewer", "name" => "Viewer" } ] },
          { "id" => "plan", "name" => "Plan",
            "values" => [ { "id" => "pro", "name" => "Pro" }, { "id" => "free", "name" => "Free" } ] }
        ]
      ))
      get workshop_idea_designs_path(@idea, ctx: "viewer,nope")
      assert_select ".clar-chip-active", text: "Viewer"
      assert_select ".clar-chip-active", text: "Pro"
      assert_select "iframe[src$=?]", "?ctx=viewer,pro"
      assert_select "a[href$=?]", "?ctx=viewer,pro", text: /Open in new tab/
    end
  end

  test "the preview shows the task's published work, else master" do
    with_design_remote(@project) do |repo, _|
      seed_master(repo)
      get workshop_idea_designs_path(@idea)
      assert_select "iframe[src=?]", "#{Designs::Publisher.base_url}/t0k/master/index.html"
      commit_files(repo, repo.worktree!("wip/REC-1"), { "designs/jobs.html" => "jobs" })
      Designs::Publisher.new(@project, repo).publish!("wip/REC-1", "wip/REC-1")
      get workshop_idea_designs_path(@idea)
      assert_select "iframe[src=?]", "#{Designs::Publisher.base_url}/t0k/wip/REC-1/index.html"
    end
  end

  test "Continue to Details moves the idea and starts writing the description" do
    assert_enqueued_with(job: Designs::DescribeJob, args: [ @idea.id ]) do
      post continue_to_details_workshop_idea_designs_path(@idea)
    end
    assert_equal "details", @idea.reload.workshop_stage
    assert_redirected_to workshop_idea_path(@idea, stage: "details")
    assert_equal "Writing the description from the designs…", flash[:clar_toast]
  end

  test "Continue to Details works without Jira" do
    @project.update!(external_type: nil)
    post continue_to_details_workshop_idea_designs_path(@idea)
    assert_equal "details", @idea.reload.workshop_stage
  end

  test "Continue to Details leaves an idea further on where it is" do
    @idea.update!(workshop_stage: "ready")
    post continue_to_details_workshop_idea_designs_path(@idea)
    assert_equal "ready", @idea.reload.workshop_stage
  end

  test "the top bar offers to update the description once the designs moved on" do
    with_design_remote(@project) do |repo, _|
      seed_master(repo)
      get workshop_idea_designs_path(@idea)
      assert_select "form[action=?]", continue_to_details_workshop_idea_designs_path(@idea)
      assert_no_match(/The designs changed since the description was written/, response.body)

      first = commit_files(repo, repo.worktree!("wip/REC-1"), { "designs/a.html" => "a" })
      @idea.update!(designs_described_sha: first)
      get workshop_idea_designs_path(@idea)
      assert_no_match(/The designs changed since the description was written/, response.body)

      commit_files(repo, repo.worktree!("wip/REC-1"), { "designs/a.html" => "b" })
      get workshop_idea_designs_path(@idea)
      assert_select "body", /The designs changed since the description was written/
      assert_enqueued_with(job: Designs::DescribeJob, args: [ @idea.id ]) do
        post describe_workshop_idea_designs_path(@idea)
      end
      assert_equal "Updating the description from the designs…", flash[:clar_toast]
    end
  end

  # Ruling P2-R26: git that cannot answer (here: no clone at all) shows no
  # count and leaves Approve to say whether there is anything.
  test "when git cannot read the design repo the pill has no count and Approve stays on" do
    get workshop_idea_designs_path(@idea)
    assert_no_match(/waiting/, response.body)
    assert_select "form[action=?] button:not([disabled])", approve_workshop_idea_designs_path(@idea)
  end
end
