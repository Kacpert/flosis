require "test_helper"

class Designs::SubjectTest < ActiveSupport::TestCase
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

  test "without Flosis's setup key there is none, and the way out is named" do
    ENV.delete("FLOSIS_DESIGNS_SETUP_API_KEY")
    subject = Designs::Subject.for(@session)
    assert_nil subject.api_key
    assert_equal "Flosis's setup key is not configured (FLOSIS_DESIGNS_SETUP_API_KEY).", subject.missing_key_message
  end

  test "the setup prompt follows the phase" do
    assert_includes Designs::Subject.for(@session).system_text, LibraryEntry.find_by!(key: "setup-design-system").current_version.body
    @setup.next_phase!
    assert_includes Designs::Subject.for(@session).system_text, LibraryEntry.find_by!(key: "setup-components").current_version.body
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

  # Ruling P5-R1: the app is read through the turn's own copy, never the live
  # checkout; setup adds the crawl bundle and the materials, read-only.
  test "a setup reads the crawl bundle and the materials, and names them and the Figma files in its prompt" do
    Dir.mktmpdir("designs") do |dir|
      @project.update_columns(workspace_dir: dir)
      crawl = File.join(@project.designs_dir, "design-crawls", "20261101T120000Z")
      FileUtils.mkdir_p(crawl)
      @setup.update!(crawl_dir: crawl)
      @project.update!(design_figma_urls: [ "https://figma.com/file/abc" ])
      @project.design_materials.attach(io: StringIO.new("brand"), filename: "brand.pdf", content_type: "application/pdf")
      subject = Designs::Subject.for(@session)
      subject.prepare!
      materials = File.join(@project.designs_dir, "design-materials")
      assert_equal [ crawl, materials ], subject.add_dirs
      assert_equal "brand", File.read(File.join(materials, "brand.pdf"))
      assert_equal "444", format("%o", File.stat(File.join(materials, "brand.pdf")).mode & 0o777)
      assert_includes subject.system_text, crawl
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

end
