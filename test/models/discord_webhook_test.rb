require "test_helper"

# A rule can only post to a webhook on its own project. If this ever stops
# being true, the alert form silently drops the channel it was posting to.
class DiscordWebhookTest < ActiveSupport::TestCase
  test "no alert rule points at a webhook belonging to another project" do
    mismatched = AlertRule.joins(:discord_webhook)
                          .where.not(discord_webhooks: { project_id: nil })
                          .where("discord_webhooks.project_id != alert_rules.project_id")

    assert_empty mismatched.to_a
  end
end
