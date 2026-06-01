class TaskDraftsController < ApplicationController
  include WorkspaceScoped

  before_action :require_employee!
  before_action :set_task

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
    @task = Task.joins(:project)
               .where(projects: { workspace_id: current_workspace.id })
               .find(params[:jira_task_id])
  end
end
