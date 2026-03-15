class JiraController < ApplicationController
  include WorkspaceScoped

  before_action :require_admin!, only: [:projects, :sync]
  before_action :require_employee!, only: [:jira_tasks]
  before_action :set_project, only: [:jira_tasks, :sync]

  def projects
    client = JiraClient.new
    render json: client.fetch_projects
  end

  def jira_tasks
    tasks = @project.tasks.jira_synced.active

    sorted = sort_tasks_for_user(tasks, current_user)

    render json: sorted.map { |t|
      {
        id: t.id,
        name: t.name,
        external_reference: t.external_reference,
        external_type: t.external_type,
        status_name: t.jira_status_name,
        assignee_email: t.assignee_email
      }
    }
  end

  def sync
    JiraSyncService.new(@project).sync
    redirect_to project_path(@project), notice: "Jira sync complete."
  end

  private

  def set_project
    @project = current_workspace.projects.find(params[:id])
  end

  def sort_tasks_for_user(tasks, user)
    tasks.sort_by do |t|
      assigned_to_me = t.assignee_email == user.email_address ? 0 : 1
      status_order = jira_status_order(t.jira_status_name)
      [assigned_to_me, status_order, t.name.downcase]
    end
  end

  def jira_status_order(status_name)
    case status_name&.downcase
    when "in progress" then 0
    when "to do" then 1
    else 2
    end
  end
end
