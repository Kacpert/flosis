require "test_helper"

# Accept designs (2026-11-21): once a task's thread is merged, its describe
# turn writes the task's next description version from the accepted designs.
class Designs::DescribeJobTest < ActiveSupport::TestCase
  LINK = "https://preview.example/test-workspace/elvium/SCRUM-70/design".freeze
  CURRENT = "## AI usage\n\nIntro paragraph.\n\n**Display**\n\n- Costs show as \"$12 ($3.23 this month)\".".freeze

  # Claude as a streaming session gives it (ClaudeCliService#start_session with
  # a block, which keeps the timeout): a tick, then the answer. during runs at
  # the tick, as something else happens while Claude works.
  class FakeCli
    attr_reader :prompt

    def initialize(text: nil, error: nil, during: nil)
      @text = text
      @error = error
      @during = during
    end

    def start_session(prompt:, new_session_id: nil)
      @prompt = prompt
      raise @error if @error

      @during&.call
      yield :tick
      { session_id: "s", response: @text.to_s, is_error: false }
    end
  end

  setup do
    @root = Pathname(Dir.mktmpdir("preview"))
    ENV["DESIGNS_PREVIEW_ROOT"] = @root.to_s
    ENV["DESIGNS_PREVIEW_URL"] = "https://preview.example"
    @project = projects(:jira_project)
    @project.update!(design_preview_token: "t0k", design_repo: "acme/designs")
    @task = @project.tasks.create!(name: "SCRUM-70 Add token calculations", external_reference: "SCRUM-70", external_type: "jira",
                                   in_pipeline: true, workshop_stage: "details")
    @task.task_drafts.create!(source: TaskDraft::REFINE_SOURCE, origin: "ai", version: 4, content: CURRENT).make_current!
    session = ChatSession.create!(project: @project, workspace: @project.workspace, user: users(:one), purpose: "designs_thread",
                                  claude_session_id: SecureRandom.uuid, codebase_path: "/tmp")
    @thread = DesignThread.create!(project: @project, task: @task, author: users(:one), title: "Add token calculations",
                                   branch: "design/SCRUM-70-add-token", status: "merged", chat_session: session,
                                   described_text: CURRENT, described_version: "v4")
    session.chat_messages.create!(role: "user", user: users(:one), content: "Let's use Euro please")
    session.chat_messages.create!(role: "assistant", kind: "summary", content: "Costs show in euro now.")
    session.chat_messages.create!(role: "assistant", kind: "summary", content: "Checked on screen: fine.", data: { "check" => true })
    @merge = DesignMerge.create!(project: @project, task: @task, design_thread: @thread, sha: "a" * 40, title: "t",
                                 branch: @thread.branch, how: "manual", user: users(:one), merged_at: Time.current,
                                 slot: "accepted/#{@thread.id}", screens: [ "admin/plans" ])
    folder = @root.join("t0k", "accepted/#{@thread.id}/__flosis")
    FileUtils.mkdir_p(folder)
    File.write(folder.join("screens.json"), { contexts: [ { id: "admin", name: "Admin" } ],
                                              screens: [ { id: "plans", context: "admin", name: "Plans" } ] }.to_json)
    File.write(folder.join("changes.json"), { own: [ [ "admin", "plans", "new" ] ], through: {} }.to_json)
  end

  teardown do
    Designs::DescribeJob.claude_factory = nil
    ENV.delete("DESIGNS_PREVIEW_ROOT")
    ENV.delete("DESIGNS_PREVIEW_URL")
    FileUtils.remove_entry(@root)
  end

  def claude(cli)
    @options = nil
    Designs::DescribeJob.claude_factory = ->(**options) { @options = options; cli }
    cli
  end

  def turn
    @turn ||= Designs::Threads.queue_describe(@thread, @merge)
  end

  def section
    "**Designs** · [Open the designs](#{LINK}) · merge commit [aaaaaaa](https://github.com/acme/designs/commit/#{'a' * 40})\n" \
      "- New (1): Admin › [Plans](#{LINK}/designs/admin/plans.html)"
  end

  def run_job
    Designs::DescribeJob.perform_now(turn.id)
    turn.reload
  end

  def system_lines = @thread.chat_session.chat_messages.where(kind: "system").order(:id).pluck(:content)

  test "the accepted designs become the next Details version, with the section under the intro" do
    cli = claude(FakeCli.new(text: "<description>\n## AI usage\n\nIntro paragraph.\n\n**Display**\n\n- Costs show as \"€12\".\n" \
                                   "</description>\n<changes>\n- Costs in euro.\n</changes>"))

    assert run_job.succeeded?
    draft = @task.reload.current_detail_draft
    assert_equal [ 5, "designs" ], [ draft.version, draft.origin ]
    assert_equal "## AI usage\n\nIntro paragraph.\n\n#{section}\n\n**Display**\n\n- Costs show as \"€12\".", draft.content
    assert_equal [ 5, [ "Costs in euro." ], false ], @merge.reload.values_at(:description_version, :description_changes, :described_fallback)
    assert_equal [ draft.content, "v5" ], @thread.reload.values_at(:described_text, :described_version)
    assert_includes system_lines, "SCRUM-70's description is now v5 · designs linked"
    assert_includes cli.prompt, "Let's use Euro please"
    assert_includes cli.prompt, "Costs show in euro now."
    assert_not_includes cli.prompt, "Checked on screen"
    assert_includes cli.prompt, "- New · Admin › Plans (designs/admin/plans.html)"
    # No tools at all (review I3): --tools "" as well as nothing pre-approved.
    assert_equal [ [], [], nil, 240, 2, "medium" ], @options.values_at(:tools, :allowed_tools, :api_key, :timeout, :max_budget_usd, :effort)
  end

  test "when Claude fails, the version still comes with the section only, and says so" do
    claude(FakeCli.new(error: ClaudeCliService::ClaudeCliError.new("timed out")))

    assert run_job.succeeded?
    assert_equal "## AI usage\n\nIntro paragraph.\n\n#{section}\n\n**Display**\n\n- Costs show as \"$12 ($3.23 this month)\".",
                 @task.reload.current_detail_draft.content
    assert_equal [ 5, [], true ], @merge.reload.values_at(:description_version, :description_changes, :described_fallback)
  end

  test "an answer without a description falls back too" do
    claude(FakeCli.new(text: "I could not do it."))

    assert run_job.succeeded?
    assert @merge.reload.described_fallback
  end

  test "a description that is ahead of the designs keeps the thread's record of what they saw" do
    @thread.update!(described_text: "An older description.", described_version: "v3")
    cli = claude(FakeCli.new(text: "<description>#{CURRENT}</description><changes></changes>"))

    assert run_job.succeeded?
    assert_includes cli.prompt, "changed after the designs were last updated (v3 → v4)"
    assert_equal [ "An older description.", "v3" ], @thread.reload.values_at(:described_text, :described_version)
  end

  test "a task in Briefing gets Details v1 from its brief and moves to Details" do
    @task.task_drafts.destroy_all
    @task.update!(workshop_stage: "briefing")
    Brief.create!(task: @task, workspace: @project.workspace, version: 2, origin: "user", status: "draft",
                  content: "Intro from the brief.").make_current!
    claude(FakeCli.new(error: ClaudeCliService::ClaudeCliError.new("down")))

    assert run_job.succeeded?
    draft = @task.reload.current_detail_draft
    assert_equal [ 1, "designs", "Intro from the brief.\n\n#{section}" ], [ draft.version, draft.origin, draft.content ]
    assert @task.stage_details?
  end

  test "an HTML current version falls back to Markdown with its links" do
    @task.task_drafts.create!(source: TaskDraft::REFINE_SOURCE, origin: "manual", version: 5,
                              content: %(<p>See <a href="https://x.test/spec">the spec</a>.</p>)).make_current!
    claude(FakeCli.new(error: ClaudeCliService::ClaudeCliError.new("down")))

    assert run_job.succeeded?
    assert_equal "See [the spec](https://x.test/spec).\n\n#{section}", @task.reload.current_detail_draft.content
  end

  test "a describe turn that was already taken is left alone" do
    claude(FakeCli.new(text: "<description>x</description>"))
    turn.update!(status: "succeeded")

    Designs::DescribeJob.perform_now(turn.id)
    assert_equal 4, @task.reload.current_detail_draft.version
  end

  # Review I1: Stop is honoured, and a turn failed meanwhile (stale, or
  # stopped by the screen) is never brought back by a late answer.
  test "a describe turn stopped while Claude works keeps nothing" do
    claude(FakeCli.new(text: "<description>x</description>",
                       during: -> { turn.update_columns(stop_requested_at: Time.current, stop_requested_by: "Kacper") }))

    assert run_job.failed?
    assert_equal DesignTurn.stopped_by("Kacper"), turn.error
    assert_equal 4, @task.reload.current_detail_draft.version
    assert_nil @merge.reload.description_version
  end

  test "a describe turn failed meanwhile is not brought back by a late answer" do
    claude(FakeCli.new(text: "<description>x</description>",
                       during: -> { turn.update_columns(status: "failed", error: DesignTurn::INTERRUPTED) }))

    Designs::DescribeJob.perform_now(turn.id)
    assert turn.reload.failed?
    assert_equal 4, @task.reload.current_detail_draft.version
  end

  # SCRUM-70
  test "the describe turn is attributed to the thread and the person who accepted" do
    claude(FakeCli.new(text: "<description>\n## AI usage\n\nIntro paragraph.\n</description>"))
    run_job

    attribution = @options[:attribution]
    assert_equal @thread, attribution.item
    assert_equal "designs", attribution.area
    assert_equal @merge.user, attribution.started_by
  end

end
