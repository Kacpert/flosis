# A Discord webhook belongs to one project, not to the whole workspace. The
# workspace column stays: it is still NOT NULL and is what the cross-tenant
# guards read.
#
# Guarded per statement: MySQL commits DDL outside the migration transaction, so
# a failure part-way must leave a re-runnable state.
class AddProjectIdToDiscordWebhooks < ActiveRecord::Migration[8.1]
  def up
    unless column_exists?(:discord_webhooks, :project_id)
      add_column :discord_webhooks, :project_id, :bigint
      add_index :discord_webhooks, :project_id
    end

    # A webhook goes to the project whose alert rules actually post to it. Only
    # when nothing references it is there no better answer than the first
    # project in its workspace. Guessing by workspace order would otherwise be
    # able to hand a webhook to a project whose alert rules then could not see
    # it in their own dropdown.
    DiscordWebhook.reset_column_information
    DiscordWebhook.where(project_id: nil).find_each do |webhook|
      used_by = AlertRule.where(discord_webhook_id: webhook.id)
                         .group(:project_id).order(Arel.sql("COUNT(*) DESC")).limit(1).pluck(:project_id).first
      fallback = Project.where(workspace_id: webhook.workspace_id).order(:id).first&.id
      target = used_by || fallback
      webhook.update_columns(project_id: target) if target
    end
  end

  def down
    remove_index :discord_webhooks, :project_id if index_exists?(:discord_webhooks, :project_id)
    remove_column :discord_webhooks, :project_id if column_exists?(:discord_webhooks, :project_id)
  end
end
