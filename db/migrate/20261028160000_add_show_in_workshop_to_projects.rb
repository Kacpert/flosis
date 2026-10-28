# Not every project belongs in Flosis. Most are created in Time & HR purely so
# hours have somewhere to land — thirteen projects existed when this was added
# and exactly one of them, Elvium, had a board, a repository or a ticket. The
# other twelve filled the project switcher and the Configuration screens with
# names nobody can do Workshop work on.
#
# So a project says for itself whether it appears in the Workshop. Time & HR is
# unaffected: hours still attach to every project, which is the whole point of
# the stubs.
#
# Guarded per statement: MySQL commits DDL outside the migration transaction,
# so a failure part-way must leave a re-runnable state.
class AddShowInWorkshopToProjects < ActiveRecord::Migration[8.1]
  def up
    unless column_exists?(:projects, :show_in_workshop)
      add_column :projects, :show_in_workshop, :boolean, default: false, null: false
    end

    Project.reset_column_information

    # Written in Ruby rather than as one UPDATE because "has a ticket" is a
    # count on another table and the readable SQL for it differs per adapter.
    say_with_time "deciding which projects belong in the Workshop" do
      with_tasks = Task.distinct.pluck(:project_id).compact.to_set

      Project.find_each do |project|
        Project.where(id: project.id).update_all(show_in_workshop: workshop?(project, with_tasks))
      end
    end
  end

  def down
    remove_column :projects, :show_in_workshop if column_exists?(:projects, :show_in_workshop)
  end

  private

  # Any sign that someone has actually done Workshop work here. Deliberately
  # NOT "does it have a membership granting something": the role backfill gave
  # every employee holding Workshop access a Project Manager row on EVERY
  # project in their workspace, so that flag is true for the HR stubs too and
  # would have kept all thirteen.
  def workshop?(project, with_tasks)
    project.external_type.present? ||
      project.jira_site.present? ||
      project.github_repo.present? ||
      with_tasks.include?(project.id)
  end
end
