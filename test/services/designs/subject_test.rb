require "test_helper"

class Designs::SubjectTest < ActiveSupport::TestCase
  include DesignRepoTestHelper
  setup do
    @project = projects(:jira_project)
    @setup = DesignSetup.create!(project: @project, started_by: users(:one))
    @session = ChatSession.create!(project: @project, workspace: @project.workspace, user: users(:one), purpose: "designs_setup",
                                   claude_session_id: SecureRandom.uuid, codebase_path: "/tmp")
  end

  test "a setup works on wip/setup from master, on Flosis's own key" do
    ENV["FLOSIS_DESIGNS_SETUP_API_KEY"] = "sk-flosis"
    subject = Designs::Subject.for(@session)
    assert_equal "wip/setup", subject.wip_branch
    assert_equal "wip/setup", subject.preview_slot
    assert_equal "master", subject.base_branch_for_new_worktree
    assert_equal "sk-flosis", subject.api_key
  ensure
    ENV.delete("FLOSIS_DESIGNS_SETUP_API_KEY")
  end

  test "without the project's key or Flosis's setup key there is none, and the way out is named" do
    ENV.delete("FLOSIS_DESIGNS_SETUP_API_KEY")
    @session.project.update!(anthropic_api_key: nil)
    subject = Designs::Subject.for(@session)
    assert_nil subject.api_key
    assert_equal Designs::TurnJob::NO_KEY, subject.missing_key_message
  end

  test "a setup turn has a browser, a thread turn has none" do
    subject = Designs::Subject.for(@session)
    assert_equal false, subject.app_copy?
    assert_equal [ DesignTurn.setup_timeout, DesignTurn.setup_budget_usd ], [ subject.timeout, subject.budget_usd ]
    assert_includes subject.tools, "mcp__flosis_browser__fill_form"

    thread = @project.design_threads.create!(author: users(:one), title: "T", branch: "design/t",
                                             chat_session: Designs::Threads.new_session(@project, users(:one)))
    other = Designs::Subject.for(thread.chat_session)
    assert_equal [ Designs::TurnJob::TOOLS, true, DesignTurn.turn_timeout ], [ other.tools, other.app_copy?, other.timeout ]
    other.with_mcp("/tmp") { |path| assert_nil path }
  end

  test "a setup turn is told the contexts by the names the browser knows them by" do
    @project.design_setup_roles.create!(name: "Hiring manager", login_url: "https://s.test/login", username: "h", password: "p", position: 1)
    message = Designs::Subject.for(@session).turn_message("Build the timesheet")
    assert_includes message, "Hiring manager: browser 2-hiring-manager, designs/hiring-manager/"
    assert message.rstrip.end_with?("Build the timesheet")
  end

  # The base prompt says a turn has no browser: a setup turn is told that
  # does not hold for it.
  test "a setup turn is told it has a browser" do
    assert_includes Designs::Subject.for(@session).system_text, "This turn has a browser"
  end

  test "the setup prompt follows the phase" do
    assert_includes Designs::Subject.for(@session).system_text, LibraryEntry.find_by!(key: "setup-design-system").current_version.body
    @setup.update!(phase: "feature")
    assert_includes Designs::Subject.for(@session).system_text, LibraryEntry.find_by!(key: "setup-feature").current_version.body
  end

  # Ruling P5-R4: one composition for the prompt, the guard and the record.
  test "the setup prompt, its forbidden texts and its version ids are one composition" do
    subject = Designs::Subject.for(@session)
    base = library_entries(:designs_base).current_version
    phase = LibraryEntry.find_by!(key: "setup-design-system").current_version
    assert_equal [ base.body, phase.body ], subject.forbidden_texts
    assert_equal [ base.id, phase.id ], subject.library_version_ids
    assert_includes subject.system_text, @project.name
  end

  test "role passwords are secrets for the leak guard" do
    @project.design_setup_roles.create!(name: "Admin", login_url: "https://app.test/login", username: "a", password: "s3cret-pass")
    assert_includes Designs::Subject.for(@session).secrets, "s3cret-pass"
  end

  # The Designs setup, feature by feature: a setup turn reads the app from
  # the repositories the run cloned (never the live checkout) and the
  # materials, all read-only, and its prompt names them and the Figma files.
  test "a setup reads the cloned repositories and the materials, and names them and the Figma files in its prompt" do
    Dir.mktmpdir("designs") do |dir|
      @project.update_columns(workspace_dir: dir)
      app = @setup.run_dir.join("apps", "1-acme-app").to_s
      FileUtils.mkdir_p(app)
      @project.update!(design_figma_urls: [ "https://figma.com/file/abc" ])
      @project.design_materials.attach(io: StringIO.new("brand"), filename: "brand.pdf", content_type: "application/pdf")
      subject = Designs::Subject.for(@session)
      subject.prepare!
      materials = File.join(@project.designs_dir, "design-materials")
      assert_equal [ app, materials ], subject.add_dirs
      assert_equal "brand", File.read(File.join(materials, "brand.pdf"))
      assert_equal "444", format("%o", File.stat(File.join(materials, "brand.pdf")).mode & 0o777)
      assert_includes subject.system_text, app
      assert_includes subject.system_text, "https://figma.com/file/abc"
      assert_not_includes subject.add_dirs, @project.repo_checkout_path
      subject.prepare!
      assert_equal [ "brand.pdf" ], Dir.children(materials)
    ensure
      FileUtils.chmod_R("u+w", dir)
    end
  end

  test "a task's turn works on its own branch, on the project's key, and reads no extra folder" do
    task = tasks(:jira_task)
    task.update!(project: @project, external_reference: "REC-1")
    @project.update!(anthropic_api_key: "sk-project")
    session = ChatSession.create!(task: task, workspace: @project.workspace, user: users(:one), purpose: "designs",
                                  claude_session_id: SecureRandom.uuid, codebase_path: "/tmp")
    subject = Designs::Subject.for(session)
    assert_equal [ "REC-1", "wip/REC-1", "wip/REC-1", "sk-project" ],
                 [ subject.slug, subject.wip_branch, subject.preview_slot, subject.api_key ]
    assert_equal [], subject.add_dirs
    assert_equal Designs::Library.compose(@project).texts, subject.forbidden_texts
  end

  test "a chat session belongs to a task or a project, never both or neither" do
    assert_not ChatSession.new(purpose: "designs_setup", workspace: @project.workspace, user: users(:one),
                               claude_session_id: "x", codebase_path: "/tmp").valid?
    assert_not ChatSession.new(purpose: "designs", task: tasks(:jira_task), project: @project, workspace: @project.workspace,
                               user: users(:one), claude_session_id: "x", codebase_path: "/tmp").valid?
  end

  test "a thread's turn works on the thread's branch, from its base, and publishes its changes against it" do
    project = projects(:jira_project)
    session = ChatSession.create!(project: project, workspace: project.workspace, user: users(:one), purpose: "designs_thread",
                                  claude_session_id: SecureRandom.uuid, codebase_path: "/tmp")
    DesignThread.create!(project: project, author: users(:one), title: "x", branch: "design/fix-the-header", base_sha: "abc1234", chat_session: session)
    subject = Designs::Subject.for(session.reload)

    assert_equal "design/fix-the-header", subject.wip_branch
    assert_equal "design/fix-the-header", subject.preview_slot
    assert_equal "abc1234", subject.base_branch_for_new_worktree
    assert_equal "abc1234", subject.publish_base
    assert_equal "fix-the-header", subject.slug
  end


  test "after master is brought in, the base moves and the chips name only what differs from master too" do
    with_design_remote do |repo, remote|
      with_remote_url(remote) do
        base = seed_master(repo, { "designs/admin/a.html" => "<title>A</title>a" })
        project = repo.project
        session = ChatSession.create!(project: project, workspace: project.workspace, user: users(:one), purpose: "designs_thread",
                                      claude_session_id: SecureRandom.uuid, codebase_path: "/tmp")
        thread = DesignThread.create!(project: project, author: users(:one), title: "x", branch: "design/x", base_sha: base, chat_session: session)
        worktree = repo.worktree!("design/x", from: base)
        own = commit_files(repo, worktree, { "designs/admin/mine.html" => "<title>Mine</title>m" })
        commit_files(repo, repo.root, { "designs/admin/theirs.html" => "<title>Theirs</title>t" })
        repo.push!("master")
        repo.merge_master_into!(worktree)
        subject = Designs::Subject.for(session.reload)

        subject.refresh_base(repo)
        assert_equal repo.head("master"), thread.reload.base_sha
        assert_equal [], subject.chips(repo, own, repo.head("design/x"))
      end
    end
  end


  test "a re-import publishes its Changes against its thread's base" do
    project = projects(:jira_project)
    thread = DesignThread.create!(project: project, author: users(:one), title: "Re-import from staging", branch: "design/re-import", base_sha: "abc1234")
    project.design_setups.create!(status: "active", phase: "feature", step: 4, started_by: users(:one), design_thread: thread)
    session = ChatSession.create!(project: project, workspace: project.workspace, user: users(:one), purpose: "designs_setup",
                                  claude_session_id: SecureRandom.uuid, codebase_path: "/tmp")
    subject = Designs::Subject.for(session)
    assert_equal [ "design/re-import", "abc1234" ], [ subject.wip_branch, subject.publish_base ]
  end

end
