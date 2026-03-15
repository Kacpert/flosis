class ProjectsController < ApplicationController
  include WorkspaceScoped

  before_action :require_admin!
  before_action :set_project, only: %i[show edit update destroy archive unarchive]

  def index
    @projects = current_workspace.projects.includes(:client, :tasks).order(:name)
    @projects = @projects.active unless params[:show_archived] == "1"
  end

  def show
    @tasks = @project.tasks.order(:name)
    @time_entries = @project.time_entries.completed.includes(:user, :task, :tags).order(started_at: :desc).limit(20)
    @total_seconds = @project.time_entries.completed.sum(:duration_seconds)
    @task_time_recap = @project.time_entries.completed
      .where.not(task_id: nil)
      .joins(:task)
      .group("tasks.id", "tasks.name", "tasks.status")
      .sum(:duration_seconds)
      .sort_by { |_, seconds| -seconds }
  end

  def new
    @project = current_workspace.projects.build
    @clients = current_workspace.clients.active.order(:name)
  end

  def create
    @project = current_workspace.projects.build(project_params)

    if @project.save
      JiraSyncService.new(@project).sync if @project.jira_connected?
      redirect_to projects_path, notice: "Project created."
    else
      @clients = current_workspace.clients.active.order(:name)
      render :new, status: :unprocessable_entity
    end
  end

  def edit
    @clients = current_workspace.clients.active.order(:name)
  end

  def update
    if @project.update(project_params)
      JiraSyncService.new(@project).sync if @project.jira_connected? && @project.saved_change_to_external_reference?
      redirect_to projects_path, notice: "Project updated."
    else
      @clients = current_workspace.clients.active.order(:name)
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @project.destroy
    redirect_to projects_path, notice: "Project deleted.", status: :see_other
  end

  def archive
    @project.update(archived: true)
    redirect_to projects_path, notice: "Project archived."
  end

  def unarchive
    @project.update(archived: false)
    redirect_to projects_path, notice: "Project restored."
  end

  private

  def set_project
    @project = current_workspace.projects.find(params[:id])
  end

  def project_params
    params.require(:project).permit(:name, :client_id, :color,
                                    :budget_type, :budget_cents, :budget_hours,
                                    :external_type, :external_reference)
  end
end
