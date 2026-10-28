require "test_helper"
require Rails.root.join("db/migrate/20260912124000_add_project_id_to_discord_webhooks")

# A rule can only post to a webhook on its own project. If this ever stops
# being true, the alert form silently drops the channel it was posting to: the
# edit modal lists only the project's own webhooks, so the chips render with
# none selected while the Send-notification switch still reads ON.
#
# There are no webhook or alert-rule fixtures, so the rows this needs are built
# here — over an empty table the invariant passes for free and protects nothing.
class DiscordWebhookTest < ActiveSupport::TestCase
  setup do
    @workspace = workspaces(:one)
    @majority = projects(:jira_project)
    @minority = projects(:other_jira_project)
    # Pre-migration shape: webhooks were workspace-wide, so one channel served
    # rules in several projects.
    @webhook = DiscordWebhook.create!(workspace: @workspace, project: nil,
                                      channel_name: "dev-alerts",
                                      url: "https://discord.com/api/webhooks/1/abc")
  end

  def rule(project, name)
    AlertRule.create!(workspace: @workspace, project: project, name: name,
                      prompt: "anything stuck?", discord_webhook: @webhook,
                      run_at_time: "09:00")
  end

  def mismatched_rules
    AlertRule.joins(:discord_webhook)
             .where.not(discord_webhooks: { project_id: nil })
             .where("discord_webhooks.project_id != alert_rules.project_id")
  end

  test "no alert rule points at a webhook belonging to another project" do
    rule(@majority, "A1")
    rule(@majority, "A2")
    minority_rule = rule(@minority, "B1")

    AddProjectIdToDiscordWebhooks.new.up

    assert_empty mismatched_rules.to_a
    assert_equal @minority.id, minority_rule.reload.discord_webhook.project_id
  end

  test "the minority project's rule keeps the same channel, on a copy of its own" do
    rule(@majority, "A1")
    rule(@majority, "A2")
    minority_rule = rule(@minority, "B1")

    AddProjectIdToDiscordWebhooks.new.up

    assert_equal @majority.id, @webhook.reload.project_id, "the original stays with the majority"
    copy = minority_rule.reload.discord_webhook
    assert_not_equal @webhook.id, copy.id
    assert_equal @webhook.channel_name, copy.channel_name
    assert_equal @webhook.url, copy.url, "same channel — the alert must keep firing where it did"
  end

  test "a webhook used by one project only is moved, not copied" do
    rule(@majority, "A1")

    assert_no_difference -> { DiscordWebhook.count } do
      AddProjectIdToDiscordWebhooks.new.up
    end

    assert_equal @majority.id, @webhook.reload.project_id
  end

  test "an unreferenced webhook falls back to a project in its workspace" do
    AddProjectIdToDiscordWebhooks.new.up

    assert_not_nil @webhook.reload.project_id
  end

  # MariaDB commits DDL outside the transaction, so a half-applied run has to be
  # safe to repeat: a second pass must not clone the copies again.
  test "re-running the backfill changes nothing and creates no further copies" do
    rule(@majority, "A1")
    rule(@majority, "A2")
    rule(@minority, "B1")
    AddProjectIdToDiscordWebhooks.new.up
    before = DiscordWebhook.order(:id).pluck(:id, :project_id, :channel_name, :url)

    assert_no_difference -> { DiscordWebhook.count } do
      AddProjectIdToDiscordWebhooks.new.up
    end

    assert_equal before, DiscordWebhook.order(:id).pluck(:id, :project_id, :channel_name, :url)
    assert_empty mismatched_rules.to_a
  end
end
