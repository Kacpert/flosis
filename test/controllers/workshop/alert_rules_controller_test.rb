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

  test "create rejects a discord_webhook from another workspace (cross-tenant guard)" do
    # A webhook that belongs to a DIFFERENT workspace must not be attachable —
    # otherwise a rule could post alerts into another workspace's Discord channel.
    foreign_webhook = DiscordWebhook.create!(workspace: workspaces(:two), channel_name: "#other",
                                             url: "https://discord.com/api/webhooks/2/def")

    assert_no_difference -> { AlertRule.count } do
      post workshop_alert_rules_path, params: {
        alert_rule: {
          name: "Sneaky rule", prompt: "watch something",
          frequency: "daily", run_at_time: "13:00", discord_webhook_id: foreign_webhook.id
        }
      }
    end

    assert_redirected_to workshop_process_path(tab: "alerts")
    assert_not_nil flash[:alert]
  end

  test "update changes the rule's fields and toasts" do
    rule = AlertRule.create!(workspace: @workspace, project: @project, discord_webhook: @webhook,
      name: "Old name", prompt: "old prompt", frequency: "daily", run_at_time: "09:00")

    patch workshop_alert_rule_path(rule), params: {
      alert_rule: { name: "New name", prompt: "new prompt", frequency: "weekly",
                    run_at_time: "15:30", discord_webhook_id: @webhook.id }
    }

    rule.reload
    assert_equal "New name", rule.name
    assert_equal "new prompt", rule.prompt
    assert_equal "weekly", rule.frequency
    assert_redirected_to workshop_process_path(tab: "alerts")
    assert_match(/updated/, flash[:clar_toast])
  end

  test "update with a blank name fails and keeps the rule unchanged" do
    rule = AlertRule.create!(workspace: @workspace, project: @project, discord_webhook: @webhook,
      name: "Keep me", prompt: "p", frequency: "daily", run_at_time: "09:00")

    patch workshop_alert_rule_path(rule), params: { alert_rule: { name: "", prompt: "p", frequency: "daily", run_at_time: "09:00" } }

    assert_equal "Keep me", rule.reload.name
    assert_not_nil flash[:alert]
  end

  test "update ignores a discord_webhook from another workspace (keeps the current one)" do
    rule = AlertRule.create!(workspace: @workspace, project: @project, discord_webhook: @webhook,
      name: "R", prompt: "p", frequency: "daily", run_at_time: "09:00")
    foreign = DiscordWebhook.create!(workspace: workspaces(:two), channel_name: "#other",
                                     url: "https://discord.com/api/webhooks/9/xyz")

    patch workshop_alert_rule_path(rule), params: {
      alert_rule: { name: "R2", prompt: "p", frequency: "daily", run_at_time: "09:00", discord_webhook_id: foreign.id }
    }

    assert_equal @webhook, rule.reload.discord_webhook, "must not reassign to a foreign workspace's webhook"
    assert_equal "R2", rule.name
  end

  test "update is scope-safe (404s for a rule outside the current workshop project)" do
    # A rule on a DIFFERENT project than the selected workshop project must not
    # be editable through this session's scope.
    other_project = projects(:other_jira_project)
    other_rule = AlertRule.create!(workspace: @workspace, project: other_project, discord_webhook: @webhook,
      name: "Foreign", prompt: "p", frequency: "daily", run_at_time: "09:00")

    patch workshop_alert_rule_path(other_rule), params: { alert_rule: { name: "hax" } }

    assert_response :not_found
    assert_equal "Foreign", other_rule.reload.name
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
