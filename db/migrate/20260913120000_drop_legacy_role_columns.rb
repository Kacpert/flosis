# The workspace-wide role and its Workshop flag, replaced by six per-project
# switches and one global privilege. Also the workspace copies of the
# configuration, now that every project carries its own.
class DropLegacyRoleColumns < ActiveRecord::Migration[8.1]
  MEMBERSHIP_COLUMNS = %i[role workshop_access].freeze

  WORKSPACE_COLUMNS = %i[
    github_repo github_token figma_read_enabled
    pr_review_enabled pr_review_prompt pr_poll_minutes pr_polled_at
    estimation_trigger estimation_status_trigger estimation_field_names
    jira_ai_actions_field_id jira_ai_estimation_field_id jira_story_points_field_id
    jira_status_ok jira_status_error jira_status_checked_at
    github_status_ok github_status_error github_status_checked_at
    figma_status_ok figma_status_error figma_status_checked_at
  ].freeze

  def up
    MEMBERSHIP_COLUMNS.each do |column|
      remove_column :workspace_memberships, column if column_exists?(:workspace_memberships, column)
    end
    WORKSPACE_COLUMNS.each do |column|
      remove_column :workspaces, column if column_exists?(:workspaces, column)
    end
  end

  # Nothing in MEMBERSHIP_COLUMNS or WORKSPACE_COLUMNS may still be read when
  # this runs — the two greps in the plan's Task 18 Step 1 are how you know,
  # and they are not optional. They caught two readers the plan itself had
  # missed: the holiday team overview, which excluded the legacy client role,
  # and nothing else.

  # Deliberately irreversible: restoring the columns would restore empty ones,
  # which is worse than refusing, because it looks like it worked.
  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
