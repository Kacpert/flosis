class JiraController < ApplicationController
  include WorkspaceScoped

  # #jira_tasks is deliberately NOT behind the Workshop product gate: it is the
  # JSON feed for the timer bar's task picker, i.e. a Time & HR surface. Most
  # employees have workshop_access = false, so gating it on Workshop left them
  # unable to log time against a Jira ticket at all (the picker silently showed
  # nothing) — the whole point of the feature.
  before_action -> { require_product!(:workshop) }, except: [ :jira_tasks ]

  before_action :require_admin!, only: [:projects, :sync]
  before_action :require_workspace_member!, only: [:jira_tasks]
  before_action :set_project, only: [:jira_tasks, :sync]
  rescue_from ActiveRecord::RecordNotFound, with: :jira_record_not_found

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
        external_url: t.external_url,
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
    # Clients/employees may only reach Jira projects they're a member of; admins
    # (the only role that reaches #sync) see all Jira projects.
    @project = visible_jira_projects.find(params[:id])
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
