class WorkshopController < ApplicationController
  include WorkspaceScoped

  before_action { require_product!(:workshop) }
  before_action :require_admin!
  before_action :require_workshop!

  def index
    # The active project comes from the top-bar Workshop project switcher.
    @project = current_workshop_project
  end

  def new_idea
    @project = workshop_projects.find_by(id: params[:project_id]) || current_workshop_project
    redirect_to(workshop_path, alert: "No Jira project selected.") and return unless @project
    @mode = params[:mode] == "new" ? "new" : "existing"
    @design_tasks = @project.design_sprint_tasks.reject { |t| t.briefs.briefed.exists? }
  end

  def start
    project = current_workspace.projects.find(params[:project_id])

    task =
      if params[:mode] == "existing"
        project.tasks.find(params[:task_id])
      else
        name = params[:title].presence || "Untitled idea"
        project.tasks.create!(name: name, description: params[:body])
      end

    redirect_to workshop_brief_path(task)
  end

  def brief
    @task = Task.where(project: current_workspace.projects).find(params[:id])
    @briefs = @task.briefs.newest_first
  end

  private

  def require_workshop!
    redirect_to root_path unless current_workspace&.workshop_enabled?
  end
end
