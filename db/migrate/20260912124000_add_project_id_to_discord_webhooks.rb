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
    #
    # Webhooks were workspace-wide before this, so one channel can be shared by
    # rules in several projects. Those get a copy of the row per project — same
    # channel, same url — and their rules are repointed at it. Assigning the
    # majority project and leaving it at that would leave the other projects'
    # rules holding a webhook their own form does not list: the alert keeps
    # firing, but opening and saving that rule silently blanks the channel.
    #
    # Ordered so a run that dies part-way is safe to repeat: the copies and the
    # repointing happen first, and the original's project_id — the only thing
    # this loop selects on — is written last.
    DiscordWebhook.reset_column_information
    DiscordWebhook.where(project_id: nil).find_each do |webhook|
      rules_per_project = AlertRule.where(discord_webhook_id: webhook.id)
                                   .where.not(project_id: nil).group(:project_id).count

      if rules_per_project.empty?
        fallback = Project.where(workspace_id: webhook.workspace_id).order(:id).first&.id
        webhook.update_columns(project_id: fallback) if fallback
        next
      end

      majority = rules_per_project.max_by { |_project_id, count| count }.first

      (rules_per_project.keys - [ majority ]).each do |project_id|
        copy = DiscordWebhook.find_or_create_by!(workspace_id: webhook.workspace_id, project_id: project_id,
                                                 channel_name: webhook.channel_name, url: webhook.url)
        AlertRule.where(discord_webhook_id: webhook.id, project_id: project_id)
                 .update_all(discord_webhook_id: copy.id)
      end

      webhook.update_columns(project_id: majority)
    end
  end

  def down
    remove_index :discord_webhooks, :project_id if index_exists?(:discord_webhooks, :project_id)
    remove_column :discord_webhooks, :project_id if column_exists?(:discord_webhooks, :project_id)
  end
end
