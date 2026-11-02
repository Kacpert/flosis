# Copies the workspace's single set of settings down to every project, so no
# project starts blank on the day the workspace columns stop being read.
class BackfillProjectConfiguration < ActiveRecord::Migration[8.1]
  COPIED = %i[
    figma_read_enabled pr_review_enabled pr_review_prompt pr_poll_minutes
    estimation_trigger estimation_status_trigger estimation_field_names
    jira_ai_actions_field_id jira_ai_estimation_field_id jira_story_points_field_id
  ].freeze

  def up
    Project.reset_column_information
    Workspace.reset_column_information

    # Several COPIED columns are NOT NULL with a default (pr_poll_minutes: 7,
    # figma_read_enabled/pr_review_enabled: false, estimation_trigger:
    # "manual", ...), so every project already reads a non-blank value there
    # the moment the column exists -- present? alone can't tell "explicitly
    # set" from "still at the column's own default". Treat "still at default"
    # as unset too, so those columns actually inherit the workspace's value.
    defaults = Project.column_defaults

    say_with_time "copying workspace configuration down to projects" do
      Workspace.find_each do |workspace|
        attrs = COPIED.index_with { |column| workspace.read_attribute(column) }.compact
        # github_repo/github_token are already per-project columns; only fill
        # the ones a project has not set for itself.
        workspace.projects.find_each do |project|
          fill = attrs.reject do |column, _|
            value = project.read_attribute(column)
            value.present? && value != defaults[column.to_s]
          end
          fill[:github_repo] ||= workspace.github_repo if project.github_repo.blank?
          fill[:github_token] ||= workspace.github_token if project.github_token.blank?
          project.update_columns(fill) if fill.any?
        end
      end
    end
  end

  def down; end
end
