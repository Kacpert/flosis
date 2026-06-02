class TaskDraftsController < ApplicationController
  include WorkspaceScoped

  before_action :require_client_or_employee!
  before_action :set_task
  rescue_from ActiveRecord::RecordNotFound, with: :jira_record_not_found

  def index
    drafts = @task.task_drafts.by_source(TaskDraft::REFINE_SOURCE).newest_first.map do |d|
      {
        id: d.id,
        content: d.content,
        created_at: d.created_at.iso8601,
        created_at_display: d.created_at.strftime("%b %d, %Y %H:%M")
      }
    end
    render json: { drafts: drafts }
  end

  private

  def set_task
    @task = Task.where(project_id: visible_jira_projects.select(:id)).find(params[:jira_task_id])
  end
end
