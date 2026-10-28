# The previous migration copied the workspace's settings to every project. For
# most columns that is right: each project starts where the workspace was and
# diverges from there. For the ones that make outbound calls it is wrong -- one
# GitHub repo copied onto thirteen projects means thirteen pollers on the same
# repository and thirteen AI reviews of the same pull request.
#
# Those settings go to the project the integration was actually about: the
# workspace's single Jira project. Where that is ambiguous this migration
# changes nothing, because a person can answer it in Configuration and a
# migration cannot.
class NarrowProjectConfigurationFanout < ActiveRecord::Migration[8.1]
  NARROWED = %i[github_repo github_token pr_review_enabled pr_review_prompt
                pr_poll_minutes pr_polled_at figma_read_enabled].freeze

  def up
    Project.reset_column_information
    Workspace.reset_column_information
    defaults = Project.column_defaults

    say_with_time "narrowing per-project integration settings to one project each" do
      Workspace.find_each do |workspace|
        candidates = workspace.projects.where(external_type: "jira")
        next unless candidates.count == 1

        primary = candidates.first
        workspace.projects.where.not(id: primary.id).find_each do |project|
          # Only take back what the backfill put there. Anything a person has
          # since set for this project is theirs.
          cleared = NARROWED.filter_map do |column|
            copied = workspace.read_attribute(column)
            next if copied.nil?
            next unless project.read_attribute(column) == copied

            [ column, defaults[column.to_s] ]
          end.to_h

          project.update_columns(cleared) if cleared.any?
        end
      end
    end
  end

  # Forward-only: restoring a value we deliberately removed would recreate the
  # fan-out it exists to undo.
  def down; end
end
