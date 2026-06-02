# The two-panel breakdown page: left shows the rendered estimate + sub-task
# breakdown (with read-only version history), right is a Claude chat to refine
# it. Generation/streaming lives in BreakdownChatSessionsController; this
# controller only renders the page and serves the saved versions as JSON.
class TaskBreakdownsController < ApplicationController
  include WorkspaceScoped

  before_action :require_client_or_employee!
  before_action :set_task
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

  private

  def parse_content(content)
    JSON.parse(content)
  rescue JSON::ParserError
    nil
  end

  def set_task
    @task = Task.where(project_id: visible_jira_projects.select(:id)).find(params[:jira_task_id])
  end
end
