require "test_helper"

# SCRUM-71: while an organization's AI is paused, nothing that would start an
# AI run starts one, and the person is told why: an admin to top up in
# Billing, anyone else to ask an admin.
class AiPausedTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    @workspace = workspaces(:one)
    @workspace.update!(workshop_enabled: true)
    @project = projects(:jira_project)
    @task = tasks(:jira_task)
    pause_ai!(@workspace)
  end

  def enter_workshop(user)
    sign_in_as(user)
    post switch_product_path, params: { product: "workshop" }
    post switch_workshop_project_path, params: { project_id: @project.id }
  end

  test "a chat message is refused before it is saved, the admin pointed to Billing" do
    enter_workshop(users(:one))
    session = ChatSession.create!(task: @task, workspace: @workspace, user: users(:one), claude_session_id: "s1",
                                  codebase_path: "/tmp", purpose: "brief")
    assert_no_difference "session.chat_messages.count" do
      post message_jira_task_brief_chat_session_path(@task), params: { content: "hi" }, as: :json
    end
    assert_response :unprocessable_entity
    assert_equal "AI paused: limit reached. Top up in Billing.", response.parsed_body["error"]
    assert_equal "admin", response.parsed_body["paused"]
  end

  test "a member is told to ask an admin" do
    enter_workshop(users(:two))
    ChatSession.create!(task: @task, workspace: @workspace, user: users(:two), claude_session_id: "s2",
                        codebase_path: "/tmp", purpose: "brief")
    post message_jira_task_brief_chat_session_path(@task), params: { content: "hi" }, as: :json
    assert_equal "AI paused: limit reached. Ask an admin to top up.", response.parsed_body["error"]
  end

  test "a new conversation does not start" do
    enter_workshop(users(:one))
    post jira_task_brief_chat_session_path(@task)
    assert_includes response.body, "AI paused: limit reached."
    assert_equal 0, ChatSession.where(task: @task, purpose: "brief").count
  end

  test "Re-estimate and Analyze queue nothing" do
    enter_workshop(users(:one))
    idea = @project.tasks.create!(name: "Idea")
    assert_no_enqueued_jobs do
      post estimate_workshop_idea_path(idea)
      assert_equal "AI paused: limit reached. Top up in Billing.", flash[:alert]
      post workshop_analyze_bug_path(jira_key: "ELV-9")
      assert_equal "AI paused: limit reached. Top up in Billing.", flash[:alert]
    end
  end

  test "a due alert rule is skipped and says so; nothing is queued" do
    travel_to Time.zone.local(2026, 11, 25, 11) do
      pause_ai!(@workspace)
      webhook = DiscordWebhook.create!(workspace: @workspace, channel_name: "#dev-alerts", url: "https://discord.com/api/webhooks/1/abc")
      rule = AlertRule.create!(workspace: @workspace, project: @project, discord_webhook: webhook, name: "Daily", prompt: "Watch.",
                               frequency: "daily", run_at_time: "10:00", active: true, created_at: Time.zone.local(2020, 1, 1))
      assert_no_enqueued_jobs(only: AlertRuleRunJob) { AlertRulesDispatchJob.perform_now }
      assert_equal "Skipped: AI paused", rule.reload.last_run_chip_label
      assert_equal :skipped, rule.last_run_status
    end
  end
end
