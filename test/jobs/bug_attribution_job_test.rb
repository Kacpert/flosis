require "test_helper"

class BugAttributionJobTest < ActiveJob::TestCase
  setup do
    @project = projects(:jira_project)
    @bug_task = @project.tasks.create!(
      name: "ELV-777 Export crashes on large CSV",
      external_type: "jira",
      external_reference: "ELV-777",
      issue_type: "Bug",
      description: "Exporting a project with >10k time entries crashes with a timeout.",
      jira_created_at: 3.days.ago
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

  def attribution_block(overrides = {})
    attrs = {
      origin_kind: "new_functionality",
      author_name: "Kacper Tarchała",
      author_email: "kacper@example.com",
      confidence: "high",
      reasoning: "Introduced in commit a1b2c3d which added CSV streaming; the buffer isn't flushed for large exports."
    }.merge(overrides)
    "<attribution>#{attrs.to_json}</attribution>"
  end

  test "valid attribution creates a done BugAttribution with all fields set" do
    with_ai(attribution_block) do
      BugAttributionJob.perform_now(@project.id, "ELV-777")
    end

    attribution = BugAttribution.find_by(project: @project, jira_key: "ELV-777")
    assert attribution.present?
    assert_equal "done", attribution.status
    assert_equal "new_functionality", attribution.origin_kind
    assert_equal "Kacper Tarchała", attribution.author_name
    assert_equal "kacper@example.com", attribution.author_email
    assert_equal "high", attribution.confidence
    assert_includes attribution.reasoning, "a1b2c3d"
    assert_not_nil attribution.analyzed_at
    assert_equal @bug_task.id, attribution.task_id
  end

  test "resolves bug title/description from an open task" do
    prompt_used = nil
    response = attribution_block
    orig = ClaudeCliService.instance_method(:start_session)
    ClaudeCliService.define_method(:start_session) do |prompt:|
      prompt_used = prompt
      { session_id: "s", response: response }
    end

    begin
      BugAttributionJob.perform_now(@project.id, "ELV-777")
    ensure
      ClaudeCliService.define_method(:start_session, orig)
    end

    assert_includes prompt_used, "ELV-777"
    assert_includes prompt_used, "Export crashes on large CSV"
    assert_includes prompt_used, "Exporting a project with >10k time entries"
  end

  test "resolves bug title/description from a delivered (fixed) issue when no open task exists" do
    delivered = @project.delivered_issues.create!(
      jira_key: "ELV-888",
      title: "Login redirect loop",
      issue_type: "Bug",
      jira_created_at: 10.days.ago
    )

    prompt_used = nil
    response = attribution_block
    orig = ClaudeCliService.instance_method(:start_session)
    ClaudeCliService.define_method(:start_session) do |prompt:|
      prompt_used = prompt
      { session_id: "s", response: response }
    end

    begin
      BugAttributionJob.perform_now(@project.id, "ELV-888")
    ensure
      ClaudeCliService.define_method(:start_session, orig)
    end

    assert_includes prompt_used, "ELV-888"
    assert_includes prompt_used, "Login redirect loop"

    attribution = BugAttribution.find_by(project: @project, jira_key: "ELV-888")
    assert_equal "done", attribution.status
    assert_nil attribution.task_id
  end

  test "a genuine CLI error records status failed and never raises" do
    with_ai_error do
      assert_nothing_raised { BugAttributionJob.perform_now(@project.id, "ELV-777") }
    end

    attribution = BugAttribution.find_by(project: @project, jira_key: "ELV-777")
    assert_equal "failed", attribution.status
  end

  test "an auth-error printed as plain text is treated as a failure, not a real verdict" do
    with_ai("Failed to authenticate. API Error: 401 Invalid authentication credentials") do
      BugAttributionJob.perform_now(@project.id, "ELV-777")
    end

    attribution = BugAttribution.find_by(project: @project, jira_key: "ELV-777")
    assert_equal "failed", attribution.status
  end

  test "garbage output with no attribution block records status failed and does not crash" do
    with_ai("Just some prose, no attribution block here, plenty long enough to not look like an error marker.") do
      assert_nothing_raised { BugAttributionJob.perform_now(@project.id, "ELV-777") }
    end

    attribution = BugAttribution.find_by(project: @project, jira_key: "ELV-777")
    assert_equal "failed", attribution.status
  end

  test "is idempotent: re-running updates the same row rather than creating a new one" do
    with_ai(attribution_block(confidence: "low")) do
      BugAttributionJob.perform_now(@project.id, "ELV-777")
    end

    assert_difference -> { BugAttribution.count }, 0 do
      with_ai(attribution_block(confidence: "high", author_name: "Revised Author")) do
        BugAttributionJob.perform_now(@project.id, "ELV-777")
      end
    end

    attribution = BugAttribution.find_by(project: @project, jira_key: "ELV-777")
    assert_equal "high", attribution.confidence
    assert_equal "Revised Author", attribution.author_name
  end

  test "a failed run followed by a successful re-run updates the same row to done" do
    with_ai_error do
      BugAttributionJob.perform_now(@project.id, "ELV-777")
    end
    assert_equal "failed", BugAttribution.find_by(project: @project, jira_key: "ELV-777").status

    assert_difference -> { BugAttribution.count }, 0 do
      with_ai(attribution_block) do
        BugAttributionJob.perform_now(@project.id, "ELV-777")
      end
    end

    assert_equal "done", BugAttribution.find_by(project: @project, jira_key: "ELV-777").status
  end

  test "does nothing and does not crash when the bug key does not exist anywhere" do
    assert_nothing_raised { BugAttributionJob.perform_now(@project.id, "ELV-NOPE") }
    assert_nil BugAttribution.find_by(project: @project, jira_key: "ELV-NOPE")
  end

  test "does nothing and does not crash when the project does not exist" do
    assert_nothing_raised { BugAttributionJob.perform_now(-1, "ELV-777") }
  end
end
