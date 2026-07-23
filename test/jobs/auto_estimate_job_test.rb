require "test_helper"

class AutoEstimateJobTest < ActiveJob::TestCase
  setup do
    @workspace = workspaces(:one)
    @task = tasks(:jira_task)
    @workspace.update!(estimation_field_names: ["AI estimation"])
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

  def fake_jira_client(field_ids: { "AI estimation" => "customfield_9001" })
    fake = Object.new
    calls = []
    fake.define_singleton_method(:fetch_field_id) { |name| field_ids[name] }
    fake.define_singleton_method(:set_number_field) do |issue_key:, field_id:, value:|
      calls << { issue_key: issue_key, field_id: field_id, value: value }
      { ok: true }
    end
    fake.define_singleton_method(:calls) { calls }
    fake
  end

  def with_jira_client(fake)
    orig = JiraClient.method(:new)
    JiraClient.define_singleton_method(:new) { |*_a, **_k| fake }
    yield
  ensure
    JiraClient.define_singleton_method(:new, orig)
  end

  def estimate_block(points: 8, rationale: "Moderate scope")
    "<estimate>#{ { points: points, rationale: rationale }.to_json }</estimate>"
  end

  test "valid estimate saves points/timestamp and writes each configured field" do
    fake = fake_jira_client
    with_jira_client(fake) do
      with_ai(estimate_block(points: 8)) do
        AutoEstimateJob.perform_now(@task.id)
      end
    end

    @task.reload
    assert_equal 8, @task.ai_estimate_points
    assert_not_nil @task.ai_estimated_at

    assert_equal 1, fake.calls.size
    call = fake.calls.first
    assert_equal @task.external_reference, call[:issue_key]
    assert_equal "customfield_9001", call[:field_id]
    assert_equal 8, call[:value]
  end

  test "writes to every configured field name, never one outside the config" do
    @workspace.update!(estimation_field_names: ["AI estimation", "Story point estimate"])
    fake = fake_jira_client(field_ids: {
      "AI estimation" => "customfield_9001",
      "Story point estimate" => "customfield_9002",
      "Confidence (1–5)" => "customfield_9999"
    })

    with_jira_client(fake) do
      with_ai(estimate_block(points: 5)) do
        AutoEstimateJob.perform_now(@task.id)
      end
    end

    field_ids_written = fake.calls.map { |c| c[:field_id] }
    assert_equal %w[customfield_9001 customfield_9002].sort, field_ids_written.sort
    assert_not_includes field_ids_written, "customfield_9999"
  end

  test "garbage output does not save an estimate or write any field" do
    fake = fake_jira_client
    with_jira_client(fake) do
      with_ai("Just some prose, no estimate block here.") do
        AutoEstimateJob.perform_now(@task.id)
      end
    end

    @task.reload
    assert_nil @task.ai_estimate_points
    assert_nil @task.ai_estimated_at
    assert_empty fake.calls
  end

  test "an arbitrary non-Fibonacci complexity number (e.g. 7) saves and writes" do
    fake = fake_jira_client
    with_jira_client(fake) do
      with_ai("<estimate>#{ { points: 7, rationale: 'x' }.to_json }</estimate>") do
        AutoEstimateJob.perform_now(@task.id)
      end
    end

    assert_equal 7, @task.reload.ai_estimate_points
    assert_equal 1, fake.calls.size
  end

  test "an invalid points value (zero) does not save or write" do
    fake = fake_jira_client
    with_jira_client(fake) do
      with_ai("<estimate>#{ { points: 0, rationale: 'x' }.to_json }</estimate>") do
        AutoEstimateJob.perform_now(@task.id)
      end
    end

    @task.reload
    assert_nil @task.ai_estimate_points
    assert_empty fake.calls
  end

  test "a genuine CLI error does not save or crash" do
    fake = fake_jira_client
    with_jira_client(fake) do
      with_ai_error do
        assert_nothing_raised { AutoEstimateJob.perform_now(@task.id) }
      end
    end

    @task.reload
    assert_nil @task.ai_estimate_points
    assert_empty fake.calls
  end

  test "an auth-error printed as plain text is not mistaken for a real estimate" do
    fake = fake_jira_client
    with_jira_client(fake) do
      with_ai("Failed to authenticate. API Error: 401 Invalid authentication credentials") do
        AutoEstimateJob.perform_now(@task.id)
      end
    end

    @task.reload
    assert_nil @task.ai_estimate_points
    assert_empty fake.calls
  end

  test "estimate once: does not call the CLI when the task already has an estimate" do
    @task.update!(ai_estimate_points: 5, ai_estimated_at: 1.day.ago, jira_updated_at: 2.days.ago)

    cli_called = false
    orig = ClaudeCliService.instance_method(:start_session)
    ClaudeCliService.define_method(:start_session) { |**_kw| cli_called = true; { session_id: "s", response: estimate_block(points: 8) } }

    fake = fake_jira_client
    begin
      with_jira_client(fake) do
        AutoEstimateJob.perform_now(@task.id)
      end
    ensure
      ClaudeCliService.define_method(:start_session, orig)
    end

    assert_not cli_called, "an already-estimated task must not be re-estimated automatically"
    @task.reload
    assert_equal 5, @task.ai_estimate_points, "existing estimate must be untouched"
    assert_empty fake.calls
  end

  test "estimate once: does NOT re-estimate even when jira_updated_at changed (no more loop)" do
    # Old behavior re-estimated on any Jira timestamp bump — which our OWN
    # estimate-write caused, creating a spam loop. Now we never auto-re-estimate.
    @task.update!(ai_estimate_points: 5, ai_estimated_at: 2.days.ago, jira_updated_at: 1.day.ago)

    fake = fake_jira_client
    with_jira_client(fake) do
      with_ai(estimate_block(points: 13)) do
        AutoEstimateJob.perform_now(@task.id)
      end
    end

    @task.reload
    assert_equal 5, @task.ai_estimate_points, "must keep the original estimate, not re-estimate"
    assert_empty fake.calls, "must not write to Jira again"
  end

  test "force: re-estimates an already-estimated task (the manual button path)" do
    @task.update!(ai_estimate_points: 5, ai_estimated_at: 2.days.ago, jira_updated_at: 3.days.ago)

    fake = fake_jira_client
    with_jira_client(fake) do
      with_ai(estimate_block(points: 13)) do
        AutoEstimateJob.perform_now(@task.id, force: true)
      end
    end

    @task.reload
    assert_equal 13, @task.ai_estimate_points, "force must bypass the estimate-once guard"
    assert_equal 1, fake.calls.size
  end

  test "does nothing when the task no longer exists" do
    assert_nothing_raised { AutoEstimateJob.perform_now(-1) }
  end
end
