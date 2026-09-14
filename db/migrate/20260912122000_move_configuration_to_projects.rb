# A project is the unit of work, so its keys and its AI settings belong to it.
# There was exactly one GitHub token on the workspace, which is one fewer than
# the number of clients.
#
# Guarded per column: MySQL commits DDL outside the migration transaction, so a
# failure part-way must leave a re-runnable state.
class MoveConfigurationToProjects < ActiveRecord::Migration[8.1]
  COLUMNS = [
    [ :team, :string, {} ],
    [ :figma_token, :text, {} ],
    [ :figma_read_enabled, :boolean, { default: false, null: false } ],
    [ :anthropic_api_key, :text, {} ],
    [ :pr_review_enabled, :boolean, { default: false, null: false } ],
    [ :pr_review_prompt, :text, {} ],
    [ :pr_poll_minutes, :integer, { default: 7, null: false } ],
    [ :pr_polled_at, :datetime, {} ],
    [ :estimation_trigger, :string, { default: "manual", null: false } ],
    [ :estimation_status_trigger, :string, { default: "Ready for dev" } ],
    [ :estimation_field_names, :json, {} ],
    [ :jira_ai_actions_field_id, :string, {} ],
    [ :jira_ai_estimation_field_id, :string, {} ],
    [ :jira_story_points_field_id, :string, {} ],
    [ :jira_status_ok, :boolean, {} ],
    [ :jira_status_error, :string, {} ],
    [ :jira_status_checked_at, :datetime, {} ],
    [ :github_status_ok, :boolean, {} ],
    [ :github_status_error, :string, {} ],
    [ :github_status_checked_at, :datetime, {} ],
    [ :figma_status_ok, :boolean, {} ],
    [ :figma_status_error, :string, {} ],
    [ :figma_status_checked_at, :datetime, {} ]
  ].freeze

  def up
    COLUMNS.each do |name, type, options|
      next if column_exists?(:projects, name)
      add_column :projects, name, type, **options
    end
  end

  def down
    COLUMNS.each { |name, _, _| remove_column :projects, name if column_exists?(:projects, name) }
  end
end
