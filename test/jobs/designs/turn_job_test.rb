require "test_helper"

class Designs::TurnJobTest < ActiveJob::TestCase
  include DesignRepoTestHelper

  setup do
    @preview_root = Dir.mktmpdir("preview")
    ENV["DESIGNS_PREVIEW_ROOT"] = @preview_root
  end

  teardown do
    ENV.delete("DESIGNS_PREVIEW_ROOT")
    FileUtils.remove_entry(@preview_root)
    Designs::TurnJob.claude_factory = nil
    Designs::TurnJob.clock = nil
  end

  # A stand-in for Claude: edits the worktree, then answers. during is called
  # with the options the CLI was built with, while the turn runs. is_error is
  # what the CLI says of a run that ended in an error.
  def fake_claude(files: {}, reply: "<summary>Did it.</summary>", raise_error: nil, during: nil, is_error: false)
    scripted_claude do |_call, _keywords, opts|
      raise raise_error if raise_error
      files.each { |p, b| FileUtils.mkdir_p(File.dirname(File.join(opts[:codebase_path], p))); File.write(File.join(opts[:codebase_path], p), b) }
      during&.call(opts)
      { session_id: "s", response: reply, is_error: is_error }
    end
  end

  # A stand-in for Claude that does what the block says on every call. The
  # calls are kept in @calls, each as [:start_session or :resume_session, keywords].
  def scripted_claude(&script)
    calls = @calls = []
    Designs::TurnJob.claude_factory = lambda do |**opts|
      Object.new.tap do |cli|
        %i[start_session resume_session].each do |call|
          cli.define_singleton_method(call) do |**keywords|
            calls << [ call, keywords ]
            script.call(call, keywords, opts)
          end
        end
      end
    end
  end

  def new_turn(task)
    session = ChatSession.create!(task: task, workspace: task.project.workspace, user: users(:one), purpose: "designs",
                                  claude_session_id: SecureRandom.uuid, codebase_path: "/tmp")
    msg = session.chat_messages.create!(role: "user", content: "Add an archive tab", user: users(:one))
    DesignTurn.create!(chat_session: session, chat_message: msg)
  end

  # The person's next message in the same chat, and its turn.
  def next_turn(session, request = "Now add a filter")
    msg = session.chat_messages.create!(role: "user", content: request, user: users(:one))
    DesignTurn.create!(chat_session: session, chat_message: msg)
  end

  # Where most tests start: master seeded, the project's own key, and the
  # task, named REC-1, on the project.
  def design_task(repo)
    seed_master(repo)
    repo.project.update!(anthropic_api_key: "sk-ant")
    tasks(:jira_task).tap { |task| task.update!(project: repo.project, external_reference: "REC-1") }
  end

  def run_turn(turn, remote)
    with_remote_url(remote) { Designs::TurnJob.perform_now(turn.id) }
    turn.reload
  end

  def remote_files(remote, branch)
    GitRunner.run!("ls-tree", "-r", "--name-only", "refs/heads/#{branch}", chdir: remote).split("\n")
  end

  def assistant_messages(turn)
    turn.chat_session.chat_messages.where(role: "assistant").ordered
  end

  # The project's app checkout, with the files committed. Not checkout!(project):
  # that moves workspace_dir, and the design repo lives there too.
  def app_checkout(project, files = {})
    project.update!(github_repo: "acme/app")
    app = project.repo_checkout_path
    FileUtils.mkdir_p(app)
    system("git", "-C", app, "init", "-q", exception: true)
    return app if files.empty?

    files.each do |path, body|
      FileUtils.mkdir_p(File.dirname(File.join(app, path)))
      File.write(File.join(app, path), body)
    end
    system("git", "-C", app, "add", "-A", exception: true)
    system("git", "-C", app, "-c", "user.name=Dev", "-c", "user.email=dev@example.com", "commit", "-q", "-m", "app",
           exception: true)
    app
  end

  test "a turn commits Claude's work to the working branch, pushes it and publishes it" do
    with_design_remote do |repo, remote|
      seed_master(repo)
      repo.project.update!(anthropic_api_key: "sk-ant")
      task = tasks(:jira_task)
      task.update!(project: repo.project, external_reference: "REC-1")
      fake_claude(files: { "designs/jobs.html" => "<p>jobs</p>" },
                  reply: "<summary>Added jobs.</summary><missing>Who can archive?</missing>")
      turn = new_turn(task)
      with_remote_url(remote) { Designs::TurnJob.perform_now(turn.id) }
      turn.reload
      assert turn.succeeded?, turn.error
      assert_equal turn.commit_sha, remote_branch_sha(remote, "wip/REC-1")
      assert File.exist?(File.join(@preview_root, repo.project.reload.design_preview_token, "wip", "REC-1", "designs", "jobs.html"))
      assert_equal %w[summary missing], turn.chat_session.chat_messages.where(role: "assistant").ordered.pluck(:kind)
    end
  end

  test "a refused change fails the turn and leaves the branch where it was" do
    with_design_remote do |repo, remote|
      seed_master(repo)
      repo.project.update!(anthropic_api_key: "sk-ant")
      task = tasks(:jira_task)
      task.update!(project: repo.project, external_reference: "REC-1")
      fake_claude(files: { ".claude/skill.md" => "x" })
      turn = new_turn(task)
      with_remote_url(remote) { Designs::TurnJob.perform_now(turn.id) }
      assert turn.reload.failed?
      assert_match(/Refused: \.claude\/skill\.md/, turn.error)
      assert_nil remote_branch_sha(remote, "wip/REC-1")
    end
  end

  # Ruling P2-R19, in place of the brief's "a change to the app checkout is
  # undone": Flosis never runs checkout or clean in the live checkout. Claude
  # reads a copy of what it has committed (Designs::AppCopy, whose own tests
  # cover what the copy holds); this is the wiring.
  test "Claude is given a copy of what the app checkout has committed, as its only extra directory" do
    with_design_remote do |repo, remote|
      task = design_task(repo)
      app = app_checkout(repo.project, { "config/routes.rb" => "get '/jobs'\n" })
      copies = nil
      fake_claude(during: lambda { |opts|
        copies = opts[:add_dirs]
        assert_equal 1, copies.size
        assert_not_equal File.realpath(app), File.realpath(copies.first), "the live checkout"
        assert_equal "get '/jobs'\n", File.read(File.join(copies.first, "config/routes.rb"))
      })

      turn = run_turn(new_turn(task), remote)

      assert turn.succeeded?, turn.error
      assert_not File.exist?(File.dirname(copies.first)), "the copy is removed, with the folder it was made in"
    end
  end

  # Ruling P2-R30.
  test "the app copy and the prompt file are gone after a turn the CLI failed, too" do
    with_design_remote do |repo, remote|
      task = design_task(repo)
      app_checkout(repo.project, { "config/routes.rb" => "get '/jobs'\n" })
      given = []
      scripted_claude do |_call, _keywords, opts|
        given.push(opts[:add_dirs].first, opts[:append_system_prompt_file])
        raise ClaudeCliService::ClaudeCliError, "Failed to parse Claude response"
      end

      turn = run_turn(new_turn(task), remote)

      assert turn.failed?
      assert_equal 2, given.uniq.size, "the copy and the prompt file, the same for both attempts"
      given.uniq.each { |path| assert_not File.exist?(path), path }
      assert_not File.exist?(File.dirname(given.first))
    end
  end

  # Ruling P2-R30. Solid Queue stops a worker with exit!, which runs no
  # ensure, so a turn a deploy killed leaves its temp files behind.
  test "a turn first clears away the temp files that killed turns left" do
    with_design_remote do |repo, remote|
      task = design_task(repo)
      long_ago = (DesignTurn.stale_after + 1.minute).ago.to_time
      old_copy = Dir.mktmpdir(Designs::AppCopy::PREFIX)
      FileUtils.mkdir(File.join(old_copy, "app"))
      File.chmod(0o555, File.join(old_copy, "app"))
      File.utime(long_ago, long_ago, old_copy)
      old_prompt, young_prompt = 2.times.map do
        File.join(Dir.tmpdir, "#{Designs::TurnJob::PROMPT_PREFIX}-test-#{SecureRandom.hex(4)}.md")
      end
      [ old_prompt, young_prompt ].each { |path| File.write(path, "a system prompt") }
      File.utime(long_ago, long_ago, old_prompt)
      fake_claude

      assert run_turn(new_turn(task), remote).succeeded?

      assert_not File.exist?(old_copy)
      assert_not File.exist?(old_prompt)
      assert File.exist?(young_prompt), "a running turn's prompt file is younger than any turn can run"
    ensure
      File.delete(young_prompt) if young_prompt && File.exist?(young_prompt)
      File.delete(old_prompt) if old_prompt && File.exist?(old_prompt)
      if old_copy && File.exist?(old_copy)
        FileUtils.chmod_R("u+w", old_copy)
        FileUtils.remove_entry(old_copy)
      end
    end
  end

  test "a project without its own API key fails the turn with the way out" do
    with_design_remote do |repo, remote|
      seed_master(repo)
      repo.project.update!(anthropic_api_key: nil)
      task = tasks(:jira_task)
      task.update!(project: repo.project)
      fake_claude
      turn = new_turn(task)
      with_remote_url(remote) { Designs::TurnJob.perform_now(turn.id) }
      assert_match(/Configuration › AI/, turn.reload.error)
    end
  end

  test "a stale running turn is failed and can be retried" do
    with_design_remote do |repo, remote|
      seed_master(repo)
      repo.project.update!(anthropic_api_key: "sk-ant")
      task = tasks(:jira_task)
      task.update!(project: repo.project, external_reference: "REC-1")
      turn = new_turn(task)
      turn.update!(status: "running", started_at: DesignTurn.stale_after.ago - 1.minute)
      fake_claude(files: { "designs/a.html" => "a" })
      with_remote_url(remote) { Designs::TurnJob.perform_now(turn.id) }
      assert turn.reload.succeeded?, "a re-delivered job takes over a stale turn"
    end
  end

  test "turns of one task never run at the same time" do
    assert_equal 1, Designs::TurnJob.concurrency_limit
  end

  # Beyond the brief.

  test "Claude works in the worktree with file tools only, on the project's key, the turn's limits and a system prompt kept outside the worktree" do
    with_design_remote do |repo, remote|
      task = design_task(repo)
      repo.project.update!(context_info: "A recruiting app for agencies.")
      seen = nil
      system_prompt = nil
      fake_claude(during: lambda { |opts|
        seen = opts
        system_prompt = File.read(opts[:append_system_prompt_file])
      })

      turn = with_env("DESIGNS_TURN_TIMEOUT_SECONDS" => "120", "DESIGNS_TURN_BUDGET_USD" => "2.5") do
        run_turn(new_turn(task), remote)
      end

      assert turn.succeeded?, turn.error
      worktree = repo.worktree!("wip/REC-1").to_s
      assert_equal %i[add_dirs allowed_tools api_key append_system_prompt_file codebase_path max_budget_usd mcp_config restricted timeout],
                   seen.keys.sort
      assert_equal worktree, seen[:codebase_path]
      assert_equal %w[Read Glob Grep Edit Write], seen[:allowed_tools]
      assert_nil seen[:mcp_config], "only a setup turn has a browser"
      assert_equal true, seen[:restricted]
      assert_equal "sk-ant", seen[:api_key]
      assert_equal 120, seen[:timeout]
      assert_equal 2.5, seen[:max_budget_usd]
      assert_equal [], seen[:add_dirs], "the project has no app checkout"
      assert_equal Designs::Prompt.system_text(project: repo.project.reload), system_prompt
      assert_not seen[:append_system_prompt_file].start_with?("#{worktree}/"), "a file in the worktree would be committed"
      assert_not File.exist?(seen[:append_system_prompt_file]), "the prompt file is removed after the turn"
      assert_equal [ Designs::Prompt.turn_message(task: task.reload, request: "Add an archive tab") ],
                   @calls.map { |_call, keywords| keywords[:prompt] }
    end
  end

  # Ruling P2-R13: any turn of the chat that has started may have started the
  # session, failed ones included.
  test "the first turn of a chat starts its Claude session, and every later one resumes it" do
    with_design_remote do |repo, remote|
      task = design_task(repo)
      fake_claude(files: { "designs/a.html" => "a" })
      first = run_turn(new_turn(task), remote)
      session = first.chat_session
      id = session.claude_session_id
      assert_equal [ [ :start_session, { prompt: @calls.dig(0, 1, :prompt), new_session_id: id } ] ], @calls

      fake_claude(raise_error: ClaudeCliService::TimeoutError.new("Claude CLI did not finish within 900 seconds and was stopped"))
      assert run_turn(next_turn(session), remote).failed?
      fake_claude(files: { "designs/b.html" => "b" })
      third = run_turn(next_turn(session, "And a search box"), remote)

      assert third.succeeded?, third.error
      assert_equal [ [ :resume_session, id ] ], @calls.map { |call, keywords| [ call, keywords[:session_id] ] }
      assert_equal id, session.reload.claude_session_id
    end
  end

  # A deploy killed the first turn mid-run and fail_stale! failed it, which
  # posts nothing in the chat: the session was started all the same.
  test "a turn after one that was cut off resumes the session, though the chat has no answer yet" do
    with_design_remote do |repo, remote|
      task = design_task(repo)
      first = new_turn(task)
      first.update!(status: "running", started_at: DesignTurn.stale_after.ago - 1.minute)
      DesignTurn.fail_stale!
      session = first.chat_session
      assert_empty session.chat_messages.where(role: "assistant")
      fake_claude(files: { "designs/a.html" => "a" })

      turn = run_turn(next_turn(session), remote)

      assert turn.succeeded?, turn.error
      assert_equal [ [ :resume_session, session.claude_session_id ] ],
                   @calls.map { |call, keywords| [ call, keywords[:session_id] ] }
    end
  end

  # Ruling P2-R13 and P2-R21: the CLI cannot resume a session whose transcript
  # is gone. The fresh session starts from the branch's last commit, not from
  # whatever the failed attempt left in the worktree.
  test "a session the CLI cannot resume is started afresh, once, under a new id and from the branch's last commit" do
    with_design_remote do |repo, remote|
      task = design_task(repo)
      fake_claude(files: { "designs/a.html" => "a" })
      session = run_turn(new_turn(task), remote).chat_session
      old_id = session.claude_session_id

      scripted_claude do |call, _keywords, opts|
        if call == :resume_session
          File.write(File.join(opts[:codebase_path], "designs/half.html"), "half done")
          raise ClaudeCliService::ClaudeCliError, "Failed to parse Claude response"
        end
        File.write(File.join(opts[:codebase_path], "designs/b.html"), "b")
        { session_id: "s", response: "<summary>Added b.</summary>" }
      end
      turn = run_turn(next_turn(session), remote)

      assert turn.succeeded?, turn.error
      new_id = session.reload.claude_session_id
      assert_not_equal old_id, new_id
      assert_match(/\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/, new_id)
      assert_equal [ [ :resume_session, old_id ], [ :start_session, new_id ] ],
                   @calls.map { |call, keywords| [ call, keywords[:session_id] || keywords[:new_session_id] ] }
      assert_includes remote_files(remote, "wip/REC-1"), "designs/b.html"
      assert_not_includes remote_files(remote, "wip/REC-1"), "designs/half.html"
    end
  end

  # Ruling P2-R13: a first turn that a deploy killed left its transcript under
  # the session's id, and the CLI will not start that id again.
  test "a first turn whose session id the CLI refuses starts under a new one" do
    with_design_remote do |repo, remote|
      task = design_task(repo)
      refused = false
      scripted_claude do |_call, keywords, _opts|
        unless refused
          refused = keywords[:new_session_id]
          raise ClaudeCliService::ClaudeCliError, "Failed to parse Claude response"
        end
        { session_id: "s", response: "<summary>Answered.</summary>" }
      end

      turn = run_turn(new_turn(task), remote)

      assert turn.succeeded?, turn.error
      new_id = turn.chat_session.reload.claude_session_id
      assert_equal [ [ :start_session, refused ], [ :start_session, new_id ] ],
                   @calls.map { |call, keywords| [ call, keywords[:new_session_id] ] }
      assert_not_equal refused, new_id
    end
  end

  # Ruling P2-R30. The CLI fails at once on a lost session or an id in use. A
  # failure after a long run had Claude at work, and a whole second run after
  # it could outlast stale_after, so the screen would show a live turn as
  # interrupted.
  test "a CLI failure after a long run fails the turn instead of running it again" do
    with_design_remote do |repo, remote|
      task = design_task(repo)
      now = 1_000.0
      Designs::TurnJob.clock = -> { now }
      scripted_claude do |_call, _keywords, _opts|
        now += Designs::TurnJob::RETRY_WINDOW.to_f + 1
        raise ClaudeCliService::ClaudeCliError, "Failed to parse Claude response"
      end
      turn = new_turn(task)
      id = turn.chat_session.claude_session_id

      turn = run_turn(turn, remote)

      assert turn.failed?
      assert_equal "Failed to parse Claude response", turn.error
      assert_equal 1, @calls.size
      assert_equal id, turn.chat_session.reload.claude_session_id
    end
  end

  test "a CLI failure within the retry window is run again as a new session" do
    with_design_remote do |repo, remote|
      task = design_task(repo)
      now = 1_000.0
      Designs::TurnJob.clock = -> { now }
      scripted_claude do |_call, _keywords, _opts|
        if @calls.one?
          now += Designs::TurnJob::RETRY_WINDOW.to_f - 1
          raise ClaudeCliService::ClaudeCliError, "Failed to parse Claude response"
        end
        { session_id: "s", response: "<summary>Answered.</summary>" }
      end

      turn = run_turn(new_turn(task), remote)

      assert turn.succeeded?, turn.error
      assert_equal %i[start_session start_session], @calls.map(&:first)
    end
  end

  test "a second failure of the CLI fails the turn" do
    with_design_remote do |repo, remote|
      task = design_task(repo)
      fake_claude(raise_error: ClaudeCliService::ClaudeCliError.new("Claude CLI not found"))

      turn = run_turn(new_turn(task), remote)

      assert turn.failed?
      assert_equal "Claude CLI not found", turn.error
      assert_equal %i[start_session start_session], @calls.map(&:first)
    end
  end

  # Ruling P2-R11: a run that went past its time had all of it.
  test "a turn that runs out of time is failed and not run again" do
    with_design_remote do |repo, remote|
      task = design_task(repo)
      timeout = ClaudeCliService::TimeoutError.new("Claude CLI did not finish within 900 seconds and was stopped")
      fake_claude(files: { "designs/a.html" => "a" }, raise_error: timeout)
      turn = new_turn(task)
      id = turn.chat_session.claude_session_id

      turn = run_turn(turn, remote)

      assert turn.failed?
      assert_equal "Claude CLI did not finish within 900 seconds and was stopped", turn.error
      assert_equal 1, @calls.size
      assert_equal id, turn.chat_session.reload.claude_session_id
    end
  end

  # Ruling P2-R12: an empty answer is what a run cut short by the cost cap or
  # the time limit gives back, and a reply of blocks only says nothing either.
  test "an answer with no summary fails the turn, and nothing Claude wrote is kept" do
    with_design_remote do |repo, remote|
      task = design_task(repo)
      master = repo.head("master")
      [ "", "<missing>Who can archive?</missing>" ].each do |reply|
        fake_claude(files: { "designs/a.html" => "a" }, reply: reply)

        turn = run_turn(new_turn(task), remote)

        assert turn.failed?, reply
        assert_equal "Claude returned no answer — it may have hit the cost cap or the time limit.", turn.error
        assert_equal master, repo.head("wip/REC-1")
        assert_nil remote_branch_sha(remote, "wip/REC-1")
        assert_not repo.worktree!("wip/REC-1").join("designs/a.html").exist?
        assert_equal [ [ "error", turn.error ] ], assistant_messages(turn).pluck(:kind, :content)
      end
    end
  end

  # Ruling P2-R29. An overload past the CLI's own retries ends the run with
  # the error as its answer, after Claude may have edited half the screens.
  test "an answer the CLI marks as an error fails the turn, and nothing Claude wrote is kept" do
    with_design_remote do |repo, remote|
      task = design_task(repo)
      master = repo.head("master")
      error = "API Error: 529 #{'{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}} ' * 8}"
      fake_claude(files: { "designs/a.html" => "a" }, reply: error, is_error: true)

      turn = run_turn(new_turn(task), remote)

      assert turn.failed?
      assert_operator error.length, :>, 300
      assert_equal "Claude stopped with an error: #{error.strip.first(300)}", turn.error
      assert_equal master, repo.head("wip/REC-1")
      assert_nil remote_branch_sha(remote, "wip/REC-1")
      assert_not repo.worktree!("wip/REC-1").join("designs/a.html").exist?
      assert_equal [ [ "error", turn.error ] ], assistant_messages(turn).pluck(:kind, :content)
    end
  end

  # The cost cap (error_max_budget_usd) ends a run with no text at all.
  test "an error answer with no text is the cost cap's, and says so" do
    with_design_remote do |repo, remote|
      task = design_task(repo)
      fake_claude(files: { "designs/a.html" => "a" }, reply: "", is_error: true)

      turn = run_turn(new_turn(task), remote)

      assert turn.failed?
      assert_equal "Claude returned no answer — it may have hit the cost cap or the time limit.", turn.error
      assert_nil remote_branch_sha(remote, "wip/REC-1")
    end
  end

  # Ruling P2-R22: a turn a deploy killed left its edits in the worktree. The
  # person saw it fail, and the next commit must not carry them.
  test "a turn starts from the branch's last commit, whatever a killed turn left in the worktree" do
    with_design_remote do |repo, remote|
      task = design_task(repo)
      dir = repo.worktree!("wip/REC-1")
      FileUtils.mkdir_p(dir.join("designs"))
      File.write(dir.join("designs/half.html"), "half done")
      File.write(dir.join("README.md"), "edited by a turn that was killed\n")
      fake_claude(files: { "designs/a.html" => "a" })

      turn = run_turn(new_turn(task), remote)

      assert turn.succeeded?, turn.error
      assert_equal %w[README.md designs/a.html runtime/flosis.js], remote_files(remote, "wip/REC-1").sort
      assert_equal "hi\n", GitRunner.run!("show", "refs/heads/wip/REC-1:README.md", chdir: remote)
      assert_not dir.join("designs/half.html").exist?
    end
  end

  # Ruling P2-R23: git run in a worktree whose .git names another repository
  # would act on that one. The worktree is removed, and the next turn checks
  # the branch out afresh.
  test "a worktree whose .git was pointed elsewhere is removed and its turn failed, and the other repository is untouched" do
    with_design_remote do |repo, remote|
      task = design_task(repo)
      other = app_checkout(repo.project, { "work.rb" => "v1\n" })
      File.write(File.join(other, "work.rb"), "v2, staged\n")
      system("git", "-C", other, "add", "work.rb", exception: true)
      status = GitRunner.run!("status", "--porcelain", chdir: other)
      fake_claude(files: { "designs/a.html" => "a" },
                  during: ->(opts) { File.write(File.join(opts[:codebase_path], ".git"), "gitdir: #{other}/.git\n") })

      turn = run_turn(new_turn(task), remote)

      assert turn.failed?
      assert_match(/no longer links to the design repo/, turn.error)
      assert_not repo.worktrees_root.join("wip__REC-1").exist?
      assert_equal status, GitRunner.run!("status", "--porcelain", chdir: other)
      assert_equal "v2, staged\n", File.read(File.join(other, "work.rb"))
      assert_nil remote_branch_sha(remote, "wip/REC-1")

      fake_claude(files: { "designs/a.html" => "a" })
      again = run_turn(next_turn(turn.chat_session), remote)
      assert again.succeeded?, again.error
      assert_includes remote_files(remote, "wip/REC-1"), "designs/a.html"
    end
  end

  # A clone made afresh has none of the remote's branches, and worktree!
  # starts a new branch from a local one.
  test "a task's first turn starts from its approved design, even when only origin has it" do
    with_design_remote do |repo, remote|
      task = design_task(repo)
      push_from_elsewhere(remote, "design/REC-1", { "designs/approved.html" => "<p>approved</p>" })
      approved = remote_branch_sha(remote, "design/REC-1")
      fake_claude(files: { "designs/next.html" => "<p>next</p>" })

      turn = run_turn(new_turn(task), remote)

      assert turn.succeeded?, turn.error
      assert_equal approved, repo.head("design/REC-1")
      assert_equal approved, GitRunner.run!("rev-parse", "refs/heads/wip/REC-1^", chdir: remote).strip
      assert_includes remote_files(remote, "wip/REC-1"), "designs/approved.html"
    end
  end

  test "a task's first turn starts from its approved design when only this clone has it" do
    with_design_remote do |repo, remote|
      task = design_task(repo)
      approved = commit_files(repo, repo.worktree!("wip/OTHER-1"), { "designs/approved.html" => "<p>approved</p>" })
      repo.point!("design/REC-1", to: approved)
      fake_claude(files: { "designs/next.html" => "<p>next</p>" })

      turn = run_turn(new_turn(task), remote)

      assert turn.succeeded?, turn.error
      assert_nil remote_branch_sha(remote, "design/REC-1"), "the approved design is only in this clone"
      assert_equal approved, GitRunner.run!("rev-parse", "refs/heads/wip/REC-1^", chdir: remote).strip
      assert_includes remote_files(remote, "wip/REC-1"), "designs/approved.html"
    end
  end

  # Ruling P2-R9: the chat shows the error as the turn keeps it, cut to fit.
  test "a failed turn says why in the chat, as the turn keeps it" do
    with_design_remote do |repo, remote|
      task = design_task(repo)
      fake_claude(raise_error: ClaudeCliService::ClaudeCliError.new("x" * 20_000))

      turn = run_turn(new_turn(task), remote)

      assert turn.failed?
      assert_equal DesignTurn::ERROR_LIMIT, turn.error.length
      assert_equal [ [ "error", turn.error ] ], assistant_messages(turn).pluck(:kind, :content)
    end
  end

  # Ruling P2-R1: every credential on the project, the design repo's token
  # among them, and Flosis's own prompt.
  test "a refusal names every rule the turn broke" do
    with_design_remote do |repo, remote|
      task = design_task(repo)
      fake_claude(files: { "designs/a.html" => "<p>#{Designs::Prompt::BASE.lines.first}</p>",
                           "designs/b.html" => "<p>token: design-token</p>", "notes.md" => "x" })

      turn = run_turn(new_turn(task), remote)

      assert turn.failed?
      assert_equal "Refused: designs/a.html contains a passage from the Flosis library; " \
                   "designs/b.html contains a stored credential; " \
                   "notes.md is outside the design repo's allowed folders", turn.error
      assert_equal [ [ "error", turn.error ] ], assistant_messages(turn).pluck(:kind, :content)
      assert_nil remote_branch_sha(remote, "wip/REC-1")
    end
  end

  test "the reply is posted as its summary, each context and each open question, and the commit is named after the task" do
    with_design_remote do |repo, remote|
      task = design_task(repo)
      first_line = "Added an archive tab to the jobs list, with a filter and a button to restore a job"
      reply = "<summary>#{first_line}\nAdmins see the tab.</summary>" \
              "<context>Role: Admin - sees the tab</context><context>Plan: Free - no archive</context>" \
              "<missing>Who can restore a job?</missing>"
      fake_claude(files: { "designs/jobs.html" => "<p>jobs</p>" }, reply: reply)

      turn = run_turn(new_turn(task), remote)

      assert turn.succeeded?, turn.error
      assert_equal [ [ "summary", "#{first_line}\nAdmins see the tab." ], [ "context", "Role: Admin - sees the tab" ],
                     [ "context", "Plan: Free - no archive" ], [ "missing", "Who can restore a job?" ] ],
                   assistant_messages(turn).pluck(:kind, :content)
      assert_operator first_line.length, :>, 72
      assert_equal "REC-1: #{first_line.truncate(72)}",
                   GitRunner.run!("log", "-1", "--format=%s", "refs/heads/wip/REC-1", chdir: remote).strip
    end
  end

  # Ruling P2-R28. Once the commit is made, it is the turn's outcome: failing
  # the turn would invite a retry that runs Claude again on work already on
  # the branch. The preview is served from this clone, so it is published all
  # the same, and the next turn's push takes the commit out.
  test "a commit that cannot be pushed is still the turn's: it is published, and goes out with the next turn" do
    skip "root writes to a read-only remote" if Process.uid.zero?

    with_design_remote do |repo, remote|
      task = design_task(repo)
      fake_claude(files: { "designs/jobs.html" => "<p>jobs</p>" }, reply: "<summary>Added jobs.</summary>")
      turn = new_turn(task)
      FileUtils.chmod_R("a-w", remote)
      begin
        turn = run_turn(turn, remote)
      ensure
        FileUtils.chmod_R("u+w", remote)
      end

      assert turn.succeeded?, turn.error
      assert_equal repo.head("wip/REC-1"), turn.commit_sha
      assert_nil remote_branch_sha(remote, "wip/REC-1")
      assert File.exist?(File.join(@preview_root, repo.project.reload.design_preview_token, "wip", "REC-1", "designs", "jobs.html"))
      messages = assistant_messages(turn).pluck(:kind, :content)
      assert_equal %w[summary system], messages.map(&:first)
      assert_match(/\ASaved, but not pushed to GitHub: git push failed: .+[^.]\. It goes out with the next turn\.\z/m,
                   messages.last.last)

      fake_claude(files: { "designs/more.html" => "<p>more</p>" })
      after = run_turn(next_turn(turn.chat_session), remote)
      assert after.succeeded?, after.error
      assert_equal after.commit_sha, remote_branch_sha(remote, "wip/REC-1")
      assert_includes remote_files(remote, "wip/REC-1"), "designs/jobs.html"
    end
  end

  test "a commit whose preview cannot be updated is still the turn's, and is pushed" do
    with_design_remote do |repo, remote|
      task = design_task(repo)
      not_a_folder = File.join(@preview_root, "not-a-folder")
      File.write(not_a_folder, "")
      fake_claude(files: { "designs/jobs.html" => "<p>jobs</p>" }, reply: "<summary>Added jobs.</summary>")

      turn = with_env("DESIGNS_PREVIEW_ROOT" => not_a_folder) { run_turn(new_turn(task), remote) }

      assert turn.succeeded?, turn.error
      assert_equal turn.commit_sha, remote_branch_sha(remote, "wip/REC-1")
      # Ruling P2-R30: what the publish failed on names the preview folder,
      # and goes to the log only.
      assert_equal [ [ "summary", "Added jobs." ],
                     [ "system", "Saved, but the preview could not be updated. It refreshes with the next turn." ] ],
                   assistant_messages(turn).pluck(:kind, :content)
    end
  end

  # Ruling P2-R31: "It refreshes with the next turn" holds for a next turn that
  # only answers a question. It commits nothing and has nothing to push, but
  # its branch has commits of its own, so it is published.
  test "a turn that changes nothing refreshes a preview the turn before it could not update" do
    with_design_remote do |repo, remote|
      task = design_task(repo)
      not_a_folder = File.join(@preview_root, "not-a-folder")
      File.write(not_a_folder, "")
      fake_claude(files: { "designs/jobs.html" => "<p>jobs</p>" })

      first = with_env("DESIGNS_PREVIEW_ROOT" => not_a_folder) { run_turn(new_turn(task), remote) }

      assert first.succeeded?, first.error
      assert_equal first.commit_sha, remote_branch_sha(remote, "wip/REC-1"), "pushed: only the publish failed"
      assert_equal [ "not-a-folder" ], Dir.children(@preview_root), "nothing is published yet"

      # with_env has put the real preview root back.
      fake_claude(reply: "<summary>Admins can archive a job.</summary>")
      second = run_turn(next_turn(first.chat_session, "Who can archive?"), remote)

      assert second.succeeded?, second.error
      assert_nil second.commit_sha
      assert File.exist?(File.join(@preview_root, repo.project.reload.design_preview_token, "wip", "REC-1", "designs", "jobs.html"))
      assert_equal "summary", assistant_messages(second).last.kind, "nothing failed this time"
    end
  end

  # Ruling P2-R30: "It goes out with the next turn" holds for a next turn that
  # changes nothing, and that turn publishes what it took out. A refused turn
  # does no network work.
  test "a turn that changes nothing still takes out what an earlier turn could not push, and publishes it" do
    skip "root writes to a read-only remote" if Process.uid.zero?

    with_design_remote do |repo, remote|
      task = design_task(repo)
      not_a_folder = File.join(@preview_root, "not-a-folder")
      File.write(not_a_folder, "")
      fake_claude(files: { "designs/jobs.html" => "<p>jobs</p>" })
      first = new_turn(task)
      FileUtils.chmod_R("a-w", remote)
      begin
        first = with_env("DESIGNS_PREVIEW_ROOT" => not_a_folder) { run_turn(first, remote) }
      ensure
        FileUtils.chmod_R("u+w", remote)
      end
      assert first.succeeded?, first.error
      assert_nil remote_branch_sha(remote, "wip/REC-1")

      fake_claude(files: { "notes.md" => "x" })
      assert run_turn(next_turn(first.chat_session, "Keep notes"), remote).failed?
      assert_nil remote_branch_sha(remote, "wip/REC-1"), "a refused turn pushes nothing"

      fake_claude(reply: "<summary>Admins can archive a job.</summary>")
      second = run_turn(next_turn(first.chat_session, "Who can archive?"), remote)

      assert second.succeeded?, second.error
      assert_nil second.commit_sha
      assert_equal first.commit_sha, remote_branch_sha(remote, "wip/REC-1")
      assert File.exist?(File.join(@preview_root, repo.project.reload.design_preview_token, "wip", "REC-1", "designs", "jobs.html"))
      assert_equal "summary", assistant_messages(second).last.kind, "nothing failed this time"
    end
  end

  # chat_messages.content is TEXT on MariaDB too, so a note is cut as an error is.
  test "a note on what did not go out is cut to fit" do
    with_design_remote do |repo, remote|
      task = design_task(repo)
      fake_claude(files: { "designs/jobs.html" => "<p>jobs</p>" })
      push = Designs::Repo.instance_method(:push!)
      Designs::Repo.define_method(:push!) { |*| raise GitRunner::Error, "x" * 20_000 }
      begin
        turn = run_turn(new_turn(task), remote)
      ensure
        Designs::Repo.define_method(:push!, push)
      end

      assert turn.succeeded?, turn.error
      note = assistant_messages(turn).where(kind: "system").sole.content
      assert_equal DesignTurn::ERROR_LIMIT, note.length
      assert note.start_with?("Saved, but not pushed to GitHub: xxx")
    end
  end

  # A question needs no change to the files.
  test "an answer that changes no file succeeds with no commit, and nothing is pushed or published" do
    with_design_remote do |repo, remote|
      task = design_task(repo)
      fake_claude(reply: "<summary>Only admins can archive, as the description says.</summary>")

      turn = run_turn(new_turn(task), remote)

      assert turn.succeeded?, turn.error
      assert_nil turn.commit_sha
      assert_nil remote_branch_sha(remote, "wip/REC-1")
      assert_empty Dir.children(@preview_root)
      assert_equal [ [ "summary", "Only admins can archive, as the description says." ] ],
                   assistant_messages(turn).pluck(:kind, :content)
    end
  end

  test "a turn that is not waiting, or is still running in time, is left alone" do
    with_design_remote do |repo, remote|
      task = design_task(repo)
      fake_claude
      turns = [ { status: "succeeded" }, { status: "failed" }, { status: "running", started_at: 1.minute.ago } ]
                .map { |attributes| new_turn(task).tap { |turn| turn.update!(attributes) } }

      turns.each { |turn| run_turn(turn, remote) }
      with_remote_url(remote) { Designs::TurnJob.perform_now(0) }

      assert_equal %w[succeeded failed running], turns.map(&:status)
      assert_empty @calls
      assert_empty ChatMessage.where(role: "assistant", chat_session: turns.map(&:chat_session))
    end
  end

  # Ruling P2-R25: what "Update from master" starts when master changed the
  # same files. The turn merges master again itself, after its clean start.
  def resolve_turn(task, paths = [ "designs/a.html" ])
    session = ChatSession.create!(task: task, workspace: task.project.workspace, user: users(:one), purpose: "designs",
                                  claude_session_id: SecureRandom.uuid, codebase_path: "/tmp")
    msg = session.chat_messages.create!(role: "user", content: DesignTurn.resolve_request(paths), user: users(:one))
    DesignTurn.create!(chat_session: session, chat_message: msg, kind: "resolve_conflicts")
  end

  # The task's branch and master, each with its own version of designs/a.html
  # (or with the files given), master pushed.
  def diverge(repo, task_files: { "designs/a.html" => "task\n" }, master_files: { "designs/a.html" => "master\n" })
    commit_files(repo, repo.root, { "designs/a.html" => "base\n" })
    repo.push!("master")
    wip = commit_files(repo, repo.worktree!("wip/REC-1"), task_files)
    commit_files(repo, repo.root, master_files)
    repo.push!("master")
    wip
  end

  def parents(repo, sha)
    GitRunner.run!("rev-list", "--parents", "-1", sha, chdir: repo.root).split.drop(1)
  end

  test "a resolving turn whose merge is clean by now brings the branch up to date without Claude" do
    with_design_remote do |repo, remote|
      task = design_task(repo)
      wip = diverge(repo, task_files: { "designs/b.html" => "b\n" }, master_files: { "designs/c.html" => "c\n" })
      fake_claude

      turn = run_turn(resolve_turn(task), remote)

      assert turn.succeeded?, turn.error
      assert_empty @calls
      assert_equal [ wip, repo.head("master") ], parents(repo, turn.commit_sha)
      assert_equal turn.commit_sha, remote_branch_sha(remote, "wip/REC-1")
      assert File.exist?(File.join(@preview_root, repo.project.reload.design_preview_token, "wip", "REC-1", "designs", "c.html"))
      assert_equal [ [ "summary", "Brought up to date with master." ] ], assistant_messages(turn).pluck(:kind, :content)
    end
  end

  test "a resolving turn has Claude resolve the files that collide, and commits the merge" do
    with_design_remote do |repo, remote|
      task = design_task(repo)
      wip = diverge(repo)
      marked = nil
      fake_claude(files: { "designs/a.html" => "task and master\n" }, reply: "<summary>Kept both.</summary>")
      # Claude is handed the file with the markers in it, and asked about it
      # by name.
      fake = Designs::TurnJob.claude_factory
      Designs::TurnJob.claude_factory = lambda do |**opts|
        marked = File.read(File.join(opts[:codebase_path], "designs/a.html"))
        fake.call(**opts)
      end

      turn = run_turn(resolve_turn(task), remote)

      assert turn.succeeded?, turn.error
      assert_match(/^<<<<<<< /, marked)
      assert_includes @calls.first.last[:prompt], "Resolve the merge conflict markers in: designs/a.html."
      assert_equal [ wip, repo.head("master") ], parents(repo, turn.commit_sha)
      assert_equal turn.commit_sha, remote_branch_sha(remote, "wip/REC-1")
      assert_equal "task and master\n", GitRunner.run!("show", "refs/heads/wip/REC-1:designs/a.html", chdir: remote)
    end
  end

  test "conflict markers left in a file fail the turn, and nothing of the merge is kept" do
    with_design_remote do |repo, remote|
      task = design_task(repo)
      wip = diverge(repo)
      fake_claude(reply: "<summary>Done.</summary>")

      turn = run_turn(resolve_turn(task), remote)

      assert turn.failed?
      assert_equal "Conflict markers are still in: designs/a.html", turn.error
      assert_equal wip, repo.head("wip/REC-1")
      dir = repo.worktree!("wip/REC-1")
      assert_equal "task\n", dir.join("designs/a.html").read
      assert_raises(GitRunner::Error) { GitRunner.run!("rev-parse", "--verify", "--quiet", "MERGE_HEAD", chdir: dir) }
    end
  end

  test "a resolving turn run again as a new session merges master again first" do
    with_design_remote do |repo, remote|
      task = design_task(repo)
      wip = diverge(repo)
      now = 1_000.0
      Designs::TurnJob.clock = -> { now }
      scripted_claude do |_call, _keywords, opts|
        raise ClaudeCliService::ClaudeCliError, "Failed to parse Claude response" if @calls.one?

        File.write(File.join(opts[:codebase_path], "designs/a.html"), "resolved\n")
        { session_id: "s", response: "<summary>Resolved.</summary>" }
      end

      turn = run_turn(resolve_turn(task), remote)

      assert turn.succeeded?, turn.error
      assert_equal %i[start_session start_session], @calls.map(&:first)
      assert_equal [ wip, repo.head("master") ], parents(repo, turn.commit_sha)
    end
  end

  test "a turn records the library versions it used" do
    with_design_remote do |repo, remote|
      seed_master(repo)
      repo.project.update!(anthropic_api_key: "sk-ant")
      task = tasks(:jira_task)
      task.update!(project: repo.project, external_reference: "REC-1")
      fake_claude(files: { "designs/a.html" => "a" })
      turn = new_turn(task)
      with_remote_url(remote) { Designs::TurnJob.perform_now(turn.id) }
      assert_equal Designs::Library.compose(repo.project).version_ids, turn.reload.library_version_ids
    end
  end

  test "a turn that copies library text is refused" do
    with_design_remote do |repo, remote|
      seed_master(repo)
      repo.project.update!(anthropic_api_key: "sk-ant")
      skill = "Always pair every primary action with a quiet secondary one and never stack more than two buttons."
      LibraryEntry.create!(kind: "skill", key: "buttons", name: "Buttons").revise!(body: skill, by: nil)
      task = tasks(:jira_task)
      task.update!(project: repo.project, external_reference: "REC-1")
      fake_claude(files: { "designs/a.html" => "<p>#{skill}</p>" })
      turn = new_turn(task)
      with_remote_url(remote) { Designs::TurnJob.perform_now(turn.id) }
      assert turn.reload.failed?
      assert_match(/passage from the Flosis library/, turn.error)
    end
  end

  # Ruling P3-R1: the prompt Claude gets and the texts the guard reads are one
  # composition, even when staff revise the library while Claude works.
  test "the guard reads the library as the turn's prompt had it" do
    with_design_remote do |repo, remote|
      task = design_task(repo)
      skill = LibraryEntry.create!(kind: "skill", key: "buttons", name: "Buttons")
      first = "Always pair every primary action with a quiet secondary one and never stack more than two buttons."
      skill.revise!(body: first, by: nil)
      fake_claude(files: { "designs/a.html" => "<p>#{first}</p>" },
                  during: ->(_) { skill.revise!(body: "Something else entirely, with no words in common at all.", by: nil) })

      turn = run_turn(new_turn(task), remote)

      assert turn.failed?
      assert_match(/passage from the Flosis library/, turn.error)
    end
  end

  # Ruling P3-R2: the record says what Claude was given, and a resolving turn
  # whose merge went through by itself gave Claude nothing.
  test "a resolving turn that needs no Claude records no library versions" do
    with_design_remote do |repo, remote|
      task = design_task(repo)
      diverge(repo, task_files: { "designs/b.html" => "b\n" }, master_files: { "designs/c.html" => "c\n" })
      fake_claude
      turn = resolve_turn(task)
      turn.update!(library_version_ids: [ 1, 2 ])

      turn = run_turn(turn, remote)

      assert turn.succeeded?, turn.error
      assert_equal [], turn.library_version_ids
    end
  end

  # Plan 5: a project's setup run, on its own session.
  def thread_turn(repo, base, request = "Add a counter under long answers")
    project = repo.project
    session = ChatSession.create!(project: project, workspace: project.workspace, user: users(:one), purpose: "designs_thread",
                                  claude_session_id: SecureRandom.uuid, codebase_path: "/tmp")
    DesignThread.create!(project: project, author: users(:one), title: request, branch: "design/add-a-counter-under",
                         base_sha: base, chat_session: session)
    msg = session.chat_messages.create!(role: "user", content: request, user: users(:one))
    DesignTurn.create!(chat_session: session, chat_message: msg)
  end

  test "a thread's turn commits on its branch, publishes it with its changes and names the screens it changed" do
    with_design_remote do |repo, remote|
      page = ->(body) { "<html><head><title>Application form</title></head><body><h1>Apply</h1>#{body}</body></html>" }
      base = seed_master(repo, { "designs/candidate/apply.html" => page.call("") })
      repo.project.update!(anthropic_api_key: "sk-ant")
      fake_claude(files: { "designs/candidate/apply.html" => page.call("<p>121 / 500</p>"),
                           "designs/candidate/status.html" => "<html><head><title>Status</title></head><body>s</body></html>" },
                  reply: "<summary>Added a character counter.</summary>")
      turn = run_turn(thread_turn(repo, base), remote)

      assert turn.succeeded?, turn.error
      assert_equal turn.commit_sha, remote_branch_sha(remote, "design/add-a-counter-under")
      slot = Pathname(@preview_root).join(repo.project.reload.design_preview_token, "design", "add-a-counter-under")
      assert slot.join("designs/candidate/apply.html").exist?
      assert_equal "new", Nokogiri::HTML5(slot.join("designs/candidate/apply.changes.html").read).at("p")["data-flosis-change"]
      reply = assistant_messages(turn).find_by(kind: "summary")
      assert_equal [ [ "apply", "candidate", "M" ], [ "status", "candidate", "+" ] ], reply.data["chips"]
      thread = DesignThread.find_by!(branch: "design/add-a-counter-under")
      assert_equal [ "candidate", "apply" ], [ thread.focus_context, thread.focus_screen ]
    end
  end

  def setup_turn(project, request = "Recreate the design system")
    DesignSetup.find_or_create_by!(project: project, status: "active") { |setup| setup.started_by = users(:one) }
    session = ChatSession.create!(project: project, workspace: project.workspace, user: users(:one), purpose: "designs_setup",
                                  claude_session_id: SecureRandom.uuid, codebase_path: "/tmp")
    msg = session.chat_messages.create!(role: "user", content: request, user: users(:one))
    DesignTurn.create!(chat_session: session, chat_message: msg)
  end

  test "a setup turn commits to wip/setup on Flosis's key" do
    with_design_remote do |repo, remote|
      seed_master(repo)
      ENV["FLOSIS_DESIGNS_SETUP_API_KEY"] = "sk-flosis"
      options = nil
      fake_claude(files: { "design-system/tokens.css" => ":root { --brand: #123456; }" },
                  reply: "<summary>Tokens read from the app.</summary>", during: ->(opts) { options = opts })
      turn = run_turn(setup_turn(repo.project), remote)
      assert turn.succeeded?, turn.error
      assert_equal "sk-flosis", options[:api_key]
      assert_equal turn.commit_sha, remote_branch_sha(remote, "wip/setup")
      assert File.exist?(File.join(@preview_root, repo.project.reload.design_preview_token, "wip", "setup", "design-system", "tokens.css"))
    ensure
      ENV.delete("FLOSIS_DESIGNS_SETUP_API_KEY")
    end
  end

  # Workshop Designs v2: the setup runs on the project's own key, as its turns
  # do; without one (and without Flosis's) it fails with the way out.
  test "a setup turn runs on the project's own key, and without any key fails with the way out" do
    with_design_remote do |repo, remote|
      seed_master(repo)
      ENV.delete("FLOSIS_DESIGNS_SETUP_API_KEY")
      repo.project.update!(anthropic_api_key: "sk-project")
      options = nil
      fake_claude(files: { "design-system/tokens.css" => ":root {}" }, during: ->(opts) { options = opts })
      turn = run_turn(setup_turn(repo.project), remote)
      assert turn.succeeded?, turn.error
      assert_equal "sk-project", options[:api_key]

      repo.project.update!(anthropic_api_key: nil)
      turn = run_turn(next_turn(turn.chat_session, "Again"), remote)
      assert turn.failed?
      assert_equal Designs::TurnJob::NO_KEY, turn.error
    end
  end

  # The Designs setup, feature by feature: a setup turn drives a browser on the
  # test environment (lib/designs_crawler/browser.mjs), signed in from the
  # states the run's sign-in left, and reads the app from the repositories
  # the run cloned.
  def setup_browser(project)
    project.update!(anthropic_api_key: "sk-project", design_app_url: "https://staging.test")
    project.design_setup_roles.create!(name: "Admin", login_url: "https://staging.test/login", username: "a", password: "p4ssword-xyz", position: 0)
    project.design_setup_roles.create!(name: "Member", login_url: "https://staging.test/login", username: "m", password: "m3mber-xyz", position: 1)
    turn = setup_turn(project)
    setup = DesignSetup.find_by!(project: project)
    setup.run_dir.join("auth").mkpath
    setup.run_dir.join("auth", "1-admin.json").write("{}")
    setup.run_dir.join("apps", "1-acme-app").mkpath
    [ turn, setup ]
  end

  test "a setup turn drives the browser, on a setup turn's bounds" do
    with_design_remote do |repo, remote|
      seed_master(repo)
      turn, setup = setup_browser(repo.project)
      options = mcp = browser = nil
      fake_claude(during: lambda { |opts|
        options = opts
        mcp = JSON.parse(File.read(opts[:mcp_config]))
        browser = File.read(mcp.dig("mcpServers", "flosis_browser", "env", "FLOSIS_BROWSER_CONFIG"))
      })
      turn = run_turn(turn, remote)

      assert turn.succeeded?, turn.error
      server = mcp.dig("mcpServers", "flosis_browser")
      assert_equal [ "node", File.join(Designs::SignIn.crawler_dir, "browser.mjs") ], [ server["command"], server["args"].first ]
      config = JSON.parse(browser)
      assert_equal "https://staging.test", config["baseUrl"]
      assert_equal [ [ "1-admin", "Admin", setup.run_dir.join("auth", "1-admin.json").to_s ] ],
                   config["contexts"].map { |context| context.values_at("slug", "name", "statePath") }, "only a context that signed in"
      assert_equal options[:codebase_path], config["worktree"]
      assert_equal setup.run_dir.join("progress.json").to_s, config["progressPath"]
      assert_includes options[:allowed_tools], "mcp__flosis_browser__compare"
      assert_includes options[:allowed_tools], "Read"
      assert_not_includes options[:allowed_tools], "mcp__flosis_browser__save_features", "only the map saves features"
      assert_equal [ DesignTurn.setup_timeout, DesignTurn.setup_budget_usd ], options.values_at(:timeout, :max_budget_usd)
      assert_not File.exist?(options[:mcp_config]), "the MCP config is gone after the turn"
    end
  end

  test "the browser's config holds no password" do
    with_design_remote do |repo, remote|
      seed_master(repo)
      turn, = setup_browser(repo.project)
      seen = []
      fake_claude(during: lambda { |opts|
        seen << File.read(opts[:mcp_config])
        seen << File.read(JSON.parse(seen.first).dig("mcpServers", "flosis_browser", "env", "FLOSIS_BROWSER_CONFIG"))
      })
      run_turn(turn, remote)
      seen.each { |text| assert_no_match(/p4ssword-xyz|m3mber-xyz/, text) }
    end
  end

  test "the map's turn may save the features" do
    with_design_remote do |repo, remote|
      seed_master(repo)
      turn, setup = setup_browser(repo.project)
      setup.update!(phase: "map")
      options = config = nil
      fake_claude(during: lambda { |opts|
        options = opts
        config = JSON.parse(File.read(JSON.parse(File.read(opts[:mcp_config])).dig("mcpServers", "flosis_browser", "env", "FLOSIS_BROWSER_CONFIG")))
      })
      run_turn(turn, remote)
      assert_includes options[:allowed_tools], "mcp__flosis_browser__save_features"
      assert_equal setup.run_dir.join("features.json").to_s, config["featuresPath"]
    end
  end

  test "a setup turn reads the cloned repositories, not the app checkout" do
    with_design_remote do |repo, remote|
      seed_master(repo)
      turn, setup = setup_browser(repo.project)
      app_checkout(repo.project, "app/views/home.html.erb" => "<h1>Home</h1>")
      options = nil
      fake_claude(during: ->(opts) { options = opts })
      run_turn(turn, remote)
      assert_includes options[:add_dirs], setup.run_dir.join("apps", "1-acme-app").to_s
      assert_empty options[:add_dirs].grep(/#{Designs::AppCopy::PREFIX}/)
    end
  end

  test "turns of one project's setup share one lock, apart from its tasks'" do
    task_turn = new_turn(tasks(:jira_task))
    turn = setup_turn(projects(:jira_project))
    assert_equal "designs-task/designs-setup-#{projects(:jira_project).id}", Designs::TurnJob.new(turn.id).concurrency_key
    assert_not_equal Designs::TurnJob.new(task_turn.id).concurrency_key, Designs::TurnJob.new(turn.id).concurrency_key
  end

  test "a setup turn refuses a stored password" do
    with_design_remote do |repo, remote|
      seed_master(repo)
      ENV["FLOSIS_DESIGNS_SETUP_API_KEY"] = "sk-flosis"
      repo.project.design_setup_roles.create!(name: "Admin", login_url: "https://app.test/login", username: "a", password: "p4ssword-xyz")
      fake_claude(files: { "designs/a.html" => "<p>p4ssword-xyz</p>" })
      turn = run_turn(setup_turn(repo.project), remote)
      assert turn.failed?
      assert_match(/contains a stored credential/, turn.error)
      assert_nil remote_branch_sha(remote, "wip/setup")
    ensure
      ENV.delete("FLOSIS_DESIGNS_SETUP_API_KEY")
    end
  end
end
