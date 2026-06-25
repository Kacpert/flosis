class JiraTasksController < ApplicationController
  include WorkspaceScoped

  before_action { require_product!(:workshop) }

  before_action :require_client_or_employee!
  before_action :require_admin!, only: [:refresh]
  rescue_from ActiveRecord::RecordNotFound, with: :jira_record_not_found

  def index
    @jira_projects = visible_jira_projects

    if params[:project_id].present?
      @selected_project = @jira_projects.find_by(id: params[:project_id])
    end
    @selected_project ||= @jira_projects.first

    if @selected_project
      @boards = @selected_project.jira_boards.order(:name)
      @selected_board = if params[:board_id].present?
        @boards.find_by(id: params[:board_id])
      end
      @selected_board ||= @boards.first

      if @selected_board
        @sprints = @selected_board.jira_sprints.active_or_future.order(:name)
        @selected_sprint = @sprints.find_by(id: params[:sprint_id]) if params[:sprint_id].present?
      end
    end

    @view_mode = params[:view].presence || "kanban"
  end

  def board_data
    @selected_project = visible_jira_projects.find(params[:project_id])
    @selected_board = @selected_project.jira_boards.find(params[:board_id])
    @view_mode = params[:view].presence || "kanban"

    @columns = @selected_board.jira_board_columns.includes(:jira_board_column_statuses)

    tasks = @selected_project.tasks.jira_synced
    if params[:sprint_id].present?
      @selected_sprint = @selected_board.jira_sprints.find(params[:sprint_id])
      tasks = tasks.where(sprint_id: @selected_sprint.jira_sprint_id)
    end

    @tasks_by_column = {}
    @columns.each do |column|
      status_names = column.jira_board_column_statuses.pluck(:jira_status_name)
      @tasks_by_column[column.id] = tasks.where(jira_status_name: status_names).order(:name)
    end

    render partial: @view_mode == "list" ? "list" : "kanban"
  end

  def show
    @task = Task.where(project_id: visible_jira_projects.select(:id)).find(params[:id])

    if turbo_frame_request?
      render partial: "task_detail"
    else
      @selected_project = @task.project
      @boards = @selected_project.jira_boards.order(:name)
      @selected_board = @boards.find_by(id: params[:board_id]) || @boards.first
      if @selected_board
        @sprints = @selected_board.jira_sprints.active_or_future.order(:name)
        @selected_sprint = @sprints.find_by(id: params[:sprint_id]) if params[:sprint_id].present?
      end
    end
  end

  def refresh
    project = current_workspace.projects.find(params[:project_id])
    JiraSyncService.new(project).sync
    redirect_to jira_tasks_path(project_id: project.id, board_id: params[:board_id], sprint_id: params[:sprint_id], view: params[:view]),
                notice: "Jira sync complete."
  rescue StandardError => e
    Rails.logger.error("[JiraTasksController] Refresh failed: #{e.message}")
    redirect_to jira_tasks_path(project_id: params[:project_id]), alert: "Could not sync with Jira. Please try again."
  end
end
