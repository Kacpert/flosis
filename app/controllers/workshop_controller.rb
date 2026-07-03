class WorkshopController < ApplicationController
  include WorkspaceScoped

  layout "workshop"

  before_action { require_product!(:workshop) }
  before_action :require_admin!
  before_action :require_workshop!

  def index
    # The active project comes from the top-bar Workshop project switcher.
    @project = current_workshop_project
    @in_progress = in_progress_ideas(@project) if @project
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

  # Tasks in this project that have a brief in progress (a brief chat session or a
  # saved brief) but aren't briefed yet — so a user can return to an idea/
  # conversation they started and left. Newest activity first.
  def in_progress_ideas(project)
    task_ids = project.tasks
      .where(id: Brief.where(status: "draft").select(:task_id))
      .or(project.tasks.where(id: ChatSession.where(purpose: "brief", status: "active").select(:task_id)))
      .pluck(:id).uniq

    project.tasks
      .where(id: task_ids)
      .where.not(id: Brief.where(status: "briefed").select(:task_id))
      .includes(:briefs)
      .sort_by { |t| -(t.briefs.map(&:updated_at).max || t.updated_at).to_i }
  end

  def require_workshop!
    redirect_to root_path unless current_workspace&.workshop_enabled?
  end
end
