require "test_helper"

class AlertRuleRunJobTest < ActiveJob::TestCase
  setup do
    @workspace = workspaces(:one)
    @project = projects(:jira_project)
    @webhook = DiscordWebhook.create!(workspace: @workspace, channel_name: "#dev-alerts", url: "https://discord.com/api/webhooks/1/abc")
    @rule = AlertRule.create!(
      workspace: @workspace, project: @project, discord_webhook: @webhook,
      name: "QA backlog watch", prompt: "If more than 4 tasks have been in QA for longer than 3 days, notify.",
      frequency: "daily", run_at_time: "13:00"
    )
  end

  def with_ai(response)
    orig = ClaudeCliService.instance_method(:start_session)
    ClaudeCliService.define_method(:start_session) { |**_kw| { session_id: "s", response: response } }
    yield
  ensure
    ClaudeCliService.define_method(:start_session, orig)
  end

  def with_ai_error
    orig = ClaudeCliService.instance_method(:start_session)
    ClaudeCliService.define_method(:start_session) { |**_kw| raise ClaudeCliService::ClaudeCliError, "boom" }
    yield
  ensure
    ClaudeCliService.define_method(:start_session, orig)
  end

  def with_webhook_post
    calls = []
    orig = DiscordWebhookClient.method(:post)
    DiscordWebhookClient.define_singleton_method(:post) { |url, content:| calls << { url: url, content: content }; { ok: true } }
    yield calls
  ensure
    DiscordWebhookClient.define_singleton_method(:post, orig)
  end

  def alert_block(fired:, summary: "2 tasks flagged", detail: "SP-1 in QA > 3 days")
    "<alert>#{ { fired: fired, summary: summary, detail: detail }.to_json }</alert>"
  end

  test "fired alert creates an ok AlertRun and posts to the discord webhook" do
    with_webhook_post do |calls|
      with_ai(alert_block(fired: true)) do
        AlertRuleRunJob.perform_now(@rule.id)
      end

      assert_equal 1, calls.size
      assert_equal @webhook.url, calls.first[:url]
      # Posts ONLY the natural message (detail), not a rule-name/summary header.
      assert_equal "SP-1 in QA > 3 days", calls.first[:content]
      refute_includes calls.first[:content], @rule.name
      refute_includes calls.first[:content], "🔔"
    end

    run = @rule.alert_runs.last
    assert run.fired
    assert_equal "ok", run.status
    # Summary is still stored on the run (for the history view), just not posted.
    assert_equal "2 tasks flagged", run.summary
    assert_not_nil @rule.reload.last_run_at
  end

  test "falls back to the summary when the AI gives no detail message" do
    with_webhook_post do |calls|
      with_ai(alert_block(fired: true, summary: "headline only", detail: "")) do
        AlertRuleRunJob.perform_now(@rule.id)
      end
      assert_equal "headline only", calls.first[:content]
    end
  end

  test "not-fired alert creates an ok AlertRun and does NOT post to discord" do
    with_webhook_post do |calls|
      with_ai(alert_block(fired: false, summary: "No condition met")) do
        AlertRuleRunJob.perform_now(@rule.id)
      end

      assert_empty calls
    end

    run = @rule.alert_runs.last
    assert_not run.fired
    assert_equal "ok", run.status
    assert_equal "No condition met", run.summary
  end

  test "a genuine CLI error records an error AlertRun, does not post, and never raises" do
    with_webhook_post do |calls|
      with_ai_error do
        assert_nothing_raised { AlertRuleRunJob.perform_now(@rule.id) }
      end
      assert_empty calls
    end

    run = @rule.alert_runs.last
    assert_equal "error", run.status
    assert_equal "Run failed", run.summary
    assert_not_nil @rule.reload.last_run_at
  end

  test "an auth-error printed as plain text is treated as a failed run, not a real verdict" do
    with_webhook_post do |calls|
      with_ai("Failed to authenticate. API Error: 401 Invalid authentication credentials") do
        AlertRuleRunJob.perform_now(@rule.id)
      end
      assert_empty calls
    end

    run = @rule.alert_runs.last
    assert_equal "error", run.status
  end

  test "garbage output with no alert block records an error run and does not crash" do
    with_webhook_post do |calls|
      with_ai("Just some prose, no alert block here, and it's plenty long enough to not look like an error marker.") do
        assert_nothing_raised { AlertRuleRunJob.perform_now(@rule.id) }
      end
      assert_empty calls
    end

    run = @rule.alert_runs.last
    assert_equal "error", run.status
  end

  test "a webhook post failure result (ok: false) does not crash the job or the recorded run" do
    orig = DiscordWebhookClient.method(:post)
    DiscordWebhookClient.define_singleton_method(:post) { |*_a, **_k| { ok: false, error: "network exploded" } }

    begin
      with_ai(alert_block(fired: true)) do
        assert_nothing_raised { AlertRuleRunJob.perform_now(@rule.id) }
      end
    ensure
      DiscordWebhookClient.define_singleton_method(:post, orig)
    end

    run = @rule.alert_runs.last
    assert run.fired
    assert_equal "ok", run.status, "the AlertRun itself succeeded even though the Discord post failed"
  end

  test "does nothing when the rule no longer exists" do
    assert_nothing_raised { AlertRuleRunJob.perform_now(-1) }
  end

  # Capture the prompt the CLI was called with.
  def capture_prompt
    captured = nil
    orig = ClaudeCliService.instance_method(:start_session)
    ClaudeCliService.define_method(:start_session) { |**kw| captured = kw[:prompt]; { session_id: "s", response: "<alert>{\"fired\":false,\"summary\":\"x\",\"detail\":\"y\"}</alert>" } }
    yield
    captured
  ensure
    ClaudeCliService.define_method(:start_session, orig)
  end

  test "the prompt includes the rule's recent run history (so the AI can vary its message)" do
    # Seed some prior runs — two fired (with messages), one quiet.
    @rule.alert_runs.create!(fired: true, summary: "Come on Alex, 6 in QA!", detail: "releases slipping", status: "ok", ran_at: 3.days.ago)
    @rule.alert_runs.create!(fired: false, summary: "quiet", detail: nil, status: "ok", ran_at: 2.days.ago)
    @rule.alert_runs.create!(fired: true, summary: "Alex, the QA pile is back", detail: "5 stuck", status: "ok", ran_at: 1.day.ago)

    prompt = capture_prompt { AlertRuleRunJob.perform_now(@rule.id) }

    assert_includes prompt, "recent history for THIS rule"
    assert_includes prompt, "Do NOT repeat previous wording"
    # The actual posted messages must appear so the AI can avoid repeating them.
    assert_includes prompt, "Come on Alex, 6 in QA!"
    assert_includes prompt, "Alex, the QA pile is back"
    assert_includes prompt, "quiet (condition not met)"
  end

  test "the recent-history section is omitted when the rule has never run" do
    prompt = capture_prompt { AlertRuleRunJob.perform_now(@rule.id) }
    refute_includes prompt, "recent history for THIS rule"
  end

  test "recent history is capped at 20 runs" do
    25.times { |i| @rule.alert_runs.create!(fired: true, summary: "msg #{i}", detail: nil, status: "ok", ran_at: (25 - i).hours.ago) }

    prompt = capture_prompt { AlertRuleRunJob.perform_now(@rule.id) }

    # The 20 newest are msg 5..24; msg 0..4 (oldest) must be excluded.
    assert_includes prompt, "msg 24"
    assert_includes prompt, "msg 5"
    refute_includes prompt, "msg 4 "
    refute_includes prompt, "msg 0 "
  end

  # ---- automation memory + issues + notify opt-in ----------------------

  def block(alert:, memory: nil, issues: nil)
    out = "<alert>#{ { fired: alert, summary: "s", detail: "hi" }.to_json }</alert>"
    out += "\n<memory>#{memory}</memory>" if memory
    out += "\n<issues>#{issues}</issues>" if issues
    out
  end

  # ---- board snapshot ------------------------------------------------------
  # A rule is written the way a person reads the board ("the Customer Acceptance
  # column on DEV board"), but a column's name is not the status behind it. On
  # production the DEV board's "Customer Acceptance" column holds the status
  # "Pre-production", while the status actually called "Customer Acceptance"
  # belongs to the Design board — so a snapshot of statuses alone sent an
  # automation to work on the wrong board's tickets without noticing.

  def snapshot_for(rule)
    AlertRuleRunJob.new.send(:board_snapshot, rule)
  end

  test "the snapshot ships each board's column layout" do
    boards = snapshot_for(@rule)[:boards]

    dev = boards.find { |b| b[:name] == "DEV board" }
    assert_not_nil dev, "every synced board must be described"
    column = dev[:columns].find { |c| c[:name] == "Customer Acceptance" }
    assert_equal [ "Pre-production" ], column[:statuses], "the column's real status, not its label"
  end

  test "a task says which column it sits in, on which board" do
    task = tasks(:jira_task)
    task.update!(jira_status_name: "Pre-production")

    entry = snapshot_for(@rule)[:tasks].find { |t| t[:key] == task.external_reference }

    assert_equal "Pre-production", entry[:status]
    assert_equal "Customer Acceptance", entry[:columns]["DEV board"]
  end

  test "the same column name on two boards does not blur together" do
    on_dev = tasks(:jira_task)
    on_dev.update!(jira_status_name: "Pre-production")
    on_design = @project.tasks.create!(
      name: "DEV-937 design ticket", external_type: "jira",
      external_reference: "DEV-937", jira_status_name: "Customer Acceptance"
    )

    tasks_by_key = snapshot_for(@rule)[:tasks].index_by { |t| t[:key] }

    assert_equal({ "DEV board" => "Customer Acceptance" }, tasks_by_key["ELV-1"][:columns])
    assert_equal({ "Design" => "Customer Acceptance (design)" }, tasks_by_key["DEV-937"][:columns])
    assert_not_equal tasks_by_key["ELV-1"][:status], tasks_by_key["DEV-937"][:status]
    assert_not_nil on_design.reload
  end

  test "a status no board maps leaves the columns map empty rather than guessing" do
    task = tasks(:jira_task)
    task.update!(jira_status_name: "Some Status Nobody Mapped")

    entry = snapshot_for(@rule)[:tasks].find { |t| t[:key] == task.external_reference }

    assert_equal({}, entry[:columns])
  end

  test "a task carries the state of the sprint it is in" do
    task = tasks(:jira_task)
    task.update!(sprint_id: jira_sprints(:future_sprint).jira_sprint_id, sprint_name: "DEV Sprint 51")

    entry = snapshot_for(@rule)[:tasks].find { |t| t[:key] == task.external_reference }

    assert_equal "future", entry[:sprint_state]
    assert_equal "DEV Sprint 51", entry[:sprint]
  end

  test "the note warns that a column is not a status" do
    note = snapshot_for(@rule)[:note]

    assert_match(/column/i, note)
    assert_match(/status/i, note)
    assert_match(/`columns`/, note)
  end

  test "persists the AI's returned memory blob" do
    with_webhook_post do
      with_ai(block(alert: false, memory: %({"scanned":["DEV-1@abc"]}))) do
        AlertRuleRunJob.perform_now(@rule.id)
      end
    end
    assert_equal %({"scanned":["DEV-1@abc"]}), @rule.reload.memory_text
  end

  test "the prompt includes the rule's current memory so the AI doesn't redo work" do
    @rule.update_column(:memory, %({"seen":42}))
    prompt = capture_prompt { AlertRuleRunJob.perform_now(@rule.id) }
    assert_includes prompt, %({"seen":42})
    assert_includes prompt, "Your memory"
  end

  test "persists AI-reported issues when the <issues> block is present" do
    with_webhook_post do
      with_ai(block(alert: false, issues: "No permission to comment on DEV-9")) do
        AlertRuleRunJob.perform_now(@rule.id)
      end
    end
    assert_equal "No permission to comment on DEV-9", @rule.reload.ai_issues_text
  end

  test "rejects an over-cap memory blob (does not save)" do
    huge = "x" * (AlertRule::MEMORY_MAX_BYTES + 1)
    with_webhook_post do
      with_ai(block(alert: false, memory: huge)) do
        AlertRuleRunJob.perform_now(@rule.id)
      end
    end
    assert_nil @rule.reload.memory
  end

  test "does NOT post to Discord when notifications are off, even if fired=true" do
    @rule.update!(notify_enabled: false, discord_webhook: nil)
    with_webhook_post do |calls|
      with_ai(block(alert: true, memory: "{}")) do
        AlertRuleRunJob.perform_now(@rule.id)
      end
      assert_empty calls, "notifications off → never post"
    end
  end

  test "uses the automation tool set (GitHub + Jira) so it can act" do
    captured = nil
    orig = ClaudeCliService.instance_method(:initialize)
    ClaudeCliService.define_method(:initialize) do |**kw|
      captured = kw[:allowed_tools]
      orig.bind(self).call(**kw)
    end
    begin
      with_webhook_post { with_ai(block(alert: false, memory: "{}")) { AlertRuleRunJob.perform_now(@rule.id) } }
    ensure
      ClaudeCliService.define_method(:initialize, orig)
    end
    assert_includes captured, "mcp__github__pull_request_read"
    assert_includes captured, "mcp__jira__jira_add_comment"
    # %w[] has no comments: a stray "#" line inside the literal turns every word
    # of the prose into its own "tool" on the CLI's --allowedTools.
    assert_empty captured.grep_v(/\A(Read|Glob|Grep|WebFetch|WebSearch|mcp__)/),
                 "the tool list must contain tool names only"
  end

  test "run regenerates the project's mcp config and passes it to the CLI" do
    captured = {}
    orig_init = ClaudeCliService.instance_method(:initialize)
    ClaudeCliService.define_method(:initialize) do |**kw|
      captured[:codebase_path] = kw[:codebase_path]
      captured[:mcp_config] = kw[:mcp_config]
      orig_init.bind(self).call(**kw)
    end
    wrote = []
    orig_write = ProjectMcpConfig.method(:write!)
    ProjectMcpConfig.define_singleton_method(:write!) { |p| wrote << p.id; "#{p.workspace_dir}/.mcp.json" }

    begin
      @rule.project.update_column(:workspace_dir, Project::ELVIUM_LEGACY_DIR)
      with_webhook_post { with_ai(block(alert: false, memory: "{}")) { AlertRuleRunJob.perform_now(@rule.id) } }
    ensure
      ClaudeCliService.define_method(:initialize, orig_init)
      ProjectMcpConfig.define_singleton_method(:write!, orig_write)
    end

    assert_includes wrote, @rule.project.id, "must regenerate mcp config before running"
    assert_equal Project::ELVIUM_LEGACY_DIR, captured[:codebase_path]
    assert_equal ProjectMcpConfig.path_for(@rule.project), captured[:mcp_config]
  end
end
