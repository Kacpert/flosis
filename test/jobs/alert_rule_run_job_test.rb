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
      assert_includes calls.first[:content], @rule.name
      assert_includes calls.first[:content], "2 tasks flagged"
    end

    run = @rule.alert_runs.last
    assert run.fired
    assert_equal "ok", run.status
    assert_equal "2 tasks flagged", run.summary
    assert_not_nil @rule.reload.last_run_at
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
end
