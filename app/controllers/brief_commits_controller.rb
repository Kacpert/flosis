# Commits a specific Brief version back to Jira (create-or-update + set the
# "AI actions" field to "Briefed"). Only marks the brief briefed when the Jira
# write actually succeeds — a failure surfaces an alert and leaves the brief a
# draft (no silent success).
class BriefCommitsController < ApplicationController
  include WorkspaceScoped

  before_action { require_product!(:workshop) }
  before_action :require_admin!
  before_action :require_workshop!

  def commit
    task = Task.where(project: current_workspace.projects).find(params[:jira_task_id])
    brief = task.briefs.find(params[:id])

    result = JiraWriter.new(workspace: current_workspace).commit_brief(brief)

    if result[:ok]
      brief.mark_briefed!
      redirect_to workshop_brief_path(task), notice: "Briefed in Jira: #{result[:key]}."
    else
      redirect_to workshop_brief_path(task), alert: "Couldn't write to Jira: #{result[:error]}"
    end
  end

  private

  def require_workshop!
    redirect_to root_path unless current_workspace&.workshop_enabled?
  end
end
