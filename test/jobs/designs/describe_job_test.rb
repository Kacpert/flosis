require "test_helper"

class Designs::DescribeJobTest < ActiveJob::TestCase
  include DesignRepoTestHelper

  teardown { Designs::TurnJob.claude_factory = nil }

  # Claude answers with this text; the options it was built with and the
  # prompt it was given are kept in @options and @prompt.
  def answer_with(text)
    test = self
    Designs::TurnJob.claude_factory = lambda do |**options|
      test.instance_variable_set(:@options, options)
      Object.new.tap do |cli|
        cli.define_singleton_method(:start_session) do |prompt:, **|
          test.instance_variable_set(:@prompt, prompt)
          { session_id: "s", response: text }
        end
      end
    end
  end

  def design_task(repo)
    seed_master(repo)
    repo.project.update!(anthropic_api_key: "sk-ant")
    tasks(:jira_task).tap { |task| task.update!(project: repo.project, external_reference: "REC-1") }
  end

  def designs_session(task)
    ChatSession.create!(task: task, workspace: task.project.workspace, user: users(:one), purpose: "designs",
                        claude_session_id: SecureRandom.uuid, codebase_path: "/tmp")
  end

  test "the designs become the current Details version" do
    with_design_remote do |repo, remote|
      task = design_task(repo)
      session = designs_session(task)
      wip = commit_files(repo, repo.worktree!("wip/REC-1"), { "designs/a.html" => "a" })
      answer_with("<draft>## Goal\nArchive offers\n## Open questions\n- Restore?</draft>")
      with_remote_url(remote) { Designs::DescribeJob.perform_now(task.id) }
      assert_equal "## Goal\nArchive offers\n## Open questions\n- Restore?", task.current_detail_draft.content
      assert_equal wip, task.reload.designs_described_sha
      version = task.current_detail_draft.version
      assert_equal [ "system", "Description v#{version} written from the designs — open Details." ],
                   [ session.chat_messages.last.kind, session.chat_messages.last.content ]
    end
  end

  test "a reply without a draft changes nothing and says so" do
    with_design_remote do |repo, remote|
      task = design_task(repo)
      session = designs_session(task)
      answer_with("I could not.")
      with_remote_url(remote) { Designs::DescribeJob.perform_now(task.id) }
      assert_nil task.current_detail_draft
      assert_nil task.reload.designs_described_sha
      assert_equal [ "error", Designs::DescribeJob::NO_DRAFT ], [ session.chat_messages.last.kind, session.chat_messages.last.content ]
    end
  end

  test "describing shares the design turn's lock" do
    assert_equal Designs::TurnJob.concurrency_key_for(1), Designs::DescribeJob.concurrency_key_for(1)
  end

  # Solid Queue keys a limit by group and key, and the group defaults to the
  # job's class: equal keys alone would not hold one back for the other.
  test "a turn and a description of one task wait on the same Solid Queue key" do
    task = tasks(:jira_task)
    session = designs_session(task)
    turn = DesignTurn.create!(chat_session: session,
                              chat_message: session.chat_messages.create!(role: "user", content: "x", user: users(:one)))
    assert_equal Designs::TurnJob.new(turn.id).concurrency_key, Designs::DescribeJob.new(task.id).concurrency_key
  end

  # Ruling P4-R1.
  test "Claude reads the task's worktree with read-only tools on the project's key, and is given no library text or app" do
    with_design_remote do |repo, remote|
      task = design_task(repo)
      designs_session(task)
      answer_with("<draft>ok</draft>")
      with_remote_url(remote) { Designs::DescribeJob.perform_now(task.id) }
      assert_equal repo.worktree_path("wip/REC-1").to_s, @options[:codebase_path]
      assert_equal [ %w[Read Glob Grep], true, "sk-ant" ], @options.values_at(:allowed_tools, :restricted, :api_key)
      assert_nil @options[:append_system_prompt_file]
      assert_empty Array(@options[:add_dirs])
      assert_not_includes @prompt, library_entries(:designs_base).current_version.body.lines.first.strip
    end
  end

  test "what was agreed and the chat's open questions are in the prompt" do
    with_design_remote do |repo, remote|
      task = design_task(repo)
      task.update!(description: "Archive offers older than a year")
      session = designs_session(task)
      session.chat_messages.create!(role: "assistant", kind: "missing", content: "Who can restore an offer?")
      answer_with("<draft>ok</draft>")
      with_remote_url(remote) { Designs::DescribeJob.perform_now(task.id) }
      assert_includes @prompt, "Archive offers older than a year"
      assert_includes @prompt, "- Who can restore an offer?"
      assert_includes @prompt, "designs/tasks/REC-1.json"
    end
  end

  test "a project without its own key is told how to add one" do
    with_design_remote do |repo, remote|
      task = design_task(repo)
      repo.project.update!(anthropic_api_key: nil)
      session = designs_session(task)
      answer_with("<draft>ok</draft>")
      with_remote_url(remote) { Designs::DescribeJob.perform_now(task.id) }
      assert_equal Designs::TurnJob::NO_KEY, session.chat_messages.last.content
      assert_nil task.current_detail_draft
    end
  end
end
