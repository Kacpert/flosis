require "test_helper"

class Workshop::DiscordWebhooksControllerTest < ActionDispatch::IntegrationTest
  setup do
    @workspace = workspaces(:one)
    @workspace.update!(workshop_enabled: true)
    @project = projects(:jira_project)
    sign_in_as(users(:one)) # admin/owner
    post switch_product_path, params: { product: "workshop" }
    post switch_workshop_project_path, params: { project_id: @project.id }
  end

  test "create adds a webhook scoped to the current workspace and toasts" do
    assert_difference -> { @workspace.discord_webhooks.count }, 1 do
      post workshop_discord_webhooks_path, params: {
        discord_webhook: { channel_name: "#dev-alerts", url: "https://discord.com/api/webhooks/1/abc" }
      }
    end

    webhook = @workspace.discord_webhooks.last
    assert_equal "#dev-alerts", webhook.channel_name
    assert_redirected_to workshop_configuration_path(tab: "integrations")
    assert_match(/webhook/i, flash[:clar_toast])
  end

  test "create with missing fields does not save and sets an alert" do
    assert_no_difference -> { DiscordWebhook.count } do
      post workshop_discord_webhooks_path, params: { discord_webhook: { channel_name: "", url: "" } }
    end

    assert_redirected_to workshop_configuration_path(tab: "integrations")
    assert_not_nil flash[:alert]
  end

  test "destroy removes an unreferenced webhook" do
    webhook = DiscordWebhook.create!(workspace: @workspace, channel_name: "#product", url: "https://discord.com/api/webhooks/2/def")

    assert_difference -> { DiscordWebhook.count }, -1 do
      delete workshop_discord_webhook_path(webhook)
    end

    assert_redirected_to workshop_configuration_path(tab: "integrations")
    assert_match(/removed/i, flash[:clar_toast])
  end

  test "destroy is blocked with a toast when the webhook is referenced by alert rules" do
    webhook = DiscordWebhook.create!(workspace: @workspace, channel_name: "#dev-alerts", url: "https://discord.com/api/webhooks/1/abc")
    AlertRule.create!(workspace: @workspace, project: @project, discord_webhook: webhook,
      name: "QA backlog watch", prompt: "Watch QA backlog.", frequency: "daily", run_at_time: "13:00")
    AlertRule.create!(workspace: @workspace, project: @project, discord_webhook: webhook,
      name: "Stale PRs", prompt: "Watch stale PRs.", frequency: "daily", run_at_time: "09:00")

    assert_no_difference -> { DiscordWebhook.count } do
      delete workshop_discord_webhook_path(webhook)
    end

    assert_redirected_to workshop_configuration_path(tab: "integrations")
    assert_match(/Webhook is used by 2 alert rules/, flash[:clar_toast] || flash[:alert])
  end

  test "destroy is scope-safe (404s for a webhook belonging to another workspace)" do
    foreign_webhook = DiscordWebhook.create!(workspace: workspaces(:two), channel_name: "#other",
      url: "https://discord.com/api/webhooks/9/xyz")

    delete workshop_discord_webhook_path(foreign_webhook)

    assert_response :not_found
    assert DiscordWebhook.exists?(foreign_webhook.id)
  end

  test "employee (non-admin) is blocked from create and destroy" do
    workspace_memberships(:two_employee).update!(workshop_access: true)
    sign_out
    sign_in_as(users(:two))
    post switch_product_path, params: { product: "workshop" }

    assert_no_difference -> { DiscordWebhook.count } do
      post workshop_discord_webhooks_path, params: {
        discord_webhook: { channel_name: "#sneaky", url: "https://discord.com/api/webhooks/3/ghi" }
      }
    end
    assert_redirected_to root_path

    webhook = DiscordWebhook.create!(workspace: @workspace, channel_name: "#dev-alerts", url: "https://discord.com/api/webhooks/1/abc")
    delete workshop_discord_webhook_path(webhook)
    assert_redirected_to root_path
    assert DiscordWebhook.exists?(webhook.id)
  end
end
