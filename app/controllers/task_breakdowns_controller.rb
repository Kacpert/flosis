# The two-panel breakdown page: left shows the rendered estimate + sub-task
# breakdown (with read-only version history), right is a Claude chat to refine
# it. Generation/streaming lives in BreakdownChatSessionsController; this
# controller only renders the page and serves the saved versions as JSON.
class TaskBreakdownsController < ApplicationController
  include WorkspaceScoped

  layout "workshop"

  before_action { require_product!(:workshop) }

  before_action { require_permission!(:tasks) }
  before_action :set_task
  # set_task must run first — :update_jira's Configuration permission is asked
  # about @task's own project, not the session's current_workshop_project.
  before_action -> { require_permission_on!(@task.project, :configuration) }, only: :update_jira
  before_action :require_workshop!, only: :update_jira
  rescue_from ActiveRecord::RecordNotFound, with: :jira_record_not_found

  # GET /jira_tasks/:jira_task_id/breakdown
  def show
    @latest_breakdown = @task.latest_breakdown
    @has_breakdown = @latest_breakdown.present?
  end

  # GET /jira_tasks/:jira_task_id/task_breakdowns (JSON list of versions)
  def index
    versions = @task.task_drafts.by_source(TaskDraft::BREAKDOWN_SOURCE).newest_first.map do |d|
      {
        id: d.id,
        breakdown: parse_content(d.content),
        created_at: d.created_at.iso8601,
        created_at_display: d.created_at.strftime("%b %d, %Y %H:%M")
      }
    end.select { |v| v[:breakdown].present? }

    render json: { versions: versions }
  end

  # POST /jira_tasks/:jira_task_id/breakdown_update_jira
  # Pushes the latest breakdown spec to the linked Jira issue. Admin + Workshop
  # only. No silent success — a failed write surfaces an alert.
  def update_jira
    result = JiraWriter.for(@task.project).commit_breakdown(@task)
    if result[:ok]
      redirect_to jira_task_breakdown_path(@task), notice: "Spec pushed to Jira: #{result[:key]}."
    else
      redirect_to jira_task_breakdown_path(@task), alert: "Couldn't write to Jira: #{result[:error]}"
    end
  end

  private

  def require_workshop!
    redirect_to root_path unless current_workspace&.workshop_enabled?
  end

  def parse_content(content)
    JSON.parse(content)
  rescue JSON::ParserError
    nil
  end

  def set_task
    @task = Task.where(project_id: visible_jira_projects.select(:id)).find(params[:jira_task_id])
  end
end
