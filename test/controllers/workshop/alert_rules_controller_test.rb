require "test_helper"

class Workshop::AlertRulesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @workspace = workspaces(:one)
    @workspace.update!(workshop_enabled: true)
    @project = projects(:jira_project)
    @webhook = DiscordWebhook.create!(workspace: @workspace, channel_name: "#dev-alerts", url: "https://discord.com/api/webhooks/1/abc")
    sign_in_as(users(:one)) # admin/owner
    post switch_product_path, params: { product: "workshop" }
    post switch_workshop_project_path, params: { project_id: @project.id }
  end

  test "create saves a new alert rule scoped to the current workshop project and toasts" do
    assert_difference -> { AlertRule.count }, 1 do
      post workshop_alert_rules_path, params: {
        alert_rule: {
          name: "QA backlog watch", prompt: "If more than 4 tasks are in QA > 3 days, notify.",
          frequency: "daily", run_at_time: "13:00", discord_webhook_id: @webhook.id
        }
      }
    end

    rule = AlertRule.last
    assert_equal @project, rule.project
    assert_equal @workspace, rule.workspace
    assert_redirected_to workshop_process_path(tab: "alerts")
    assert_match(/Alert rule created/, flash[:clar_toast])
    assert_match(/QA backlog watch/, flash[:clar_toast])
  end

  test "create with missing required fields does not save and sets an alert" do
    assert_no_difference -> { AlertRule.count } do
      post workshop_alert_rules_path, params: { alert_rule: { name: "", prompt: "", frequency: "daily" } }
    end

    assert_redirected_to workshop_process_path(tab: "alerts")
    assert_not_nil flash[:alert]
  end

  test "destroy removes the rule" do
    rule = AlertRule.create!(workspace: @workspace, project: @project, discord_webhook: @webhook,
      name: "Stale PR reminder", prompt: "If a PR has no activity for 2 days, remind.",
      frequency: "daily", run_at_time: "17:30")

    assert_difference -> { AlertRule.count }, -1 do
      delete workshop_alert_rule_path(rule)
    end

    assert_redirected_to workshop_process_path(tab: "alerts")
    assert_match(/removed/, flash[:clar_toast])
  end

  test "destroy is scope-safe (404s for a rule outside the current workshop project)" do
    other_project = projects(:other_jira_project)
    rule = AlertRule.create!(workspace: @workspace, project: other_project, discord_webhook: @webhook,
      name: "Other project rule", prompt: "Watch something else.",
      frequency: "daily", run_at_time: "09:00")

    delete workshop_alert_rule_path(rule)

    assert_response :not_found
    assert AlertRule.exists?(rule.id)
  end

  test "history renders the run timeline with fired count" do
    rule = AlertRule.create!(workspace: @workspace, project: @project, discord_webhook: @webhook,
      name: "QA backlog watch", prompt: "Watch QA backlog.",
      frequency: "daily", run_at_time: "13:00")
    rule.alert_runs.create!(fired: true, summary: "2 tasks flagged", detail: "SP-1, SP-2 in QA", status: "ok", ran_at: 1.hour.ago)
    rule.alert_runs.create!(fired: false, summary: "No condition met", status: "ok", ran_at: 2.hours.ago)

    get history_workshop_alert_rule_path(rule)

    assert_response :success
    assert_match(/Fired 1 of 2 runs/, response.body)
    assert_match(/2 tasks flagged/, response.body)
    assert_match(/NOTIFIED/, response.body)
    assert_match(/NO ACTION/, response.body)
  end

  test "history is scope-safe (404s for a rule outside the current workshop project)" do
    other_project = projects(:other_jira_project)
    rule = AlertRule.create!(workspace: @workspace, project: other_project, discord_webhook: @webhook,
      name: "Other project rule", prompt: "Watch something else.",
      frequency: "daily", run_at_time: "09:00")

    get history_workshop_alert_rule_path(rule)

    assert_response :not_found
  end
end
