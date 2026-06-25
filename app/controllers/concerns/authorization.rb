module Authorization
  extend ActiveSupport::Concern

  included do
    helper_method :current_membership, :can_see_money?, :visible_jira_projects, :github_connection_problem?
  end

  private

  # True when a GitHub token is configured but the last health check failed —
  # drives the admin-only error banner.
  def github_connection_problem?
    current_workspace&.github_token.present? && current_workspace.github_status_ok == false
  end

  def current_membership
    @current_membership ||= current_user&.membership_for(current_workspace)
  end

  # Jira projects the current user may see. Admins/owners see every Jira project
  # in the workspace; everyone else (employee, client) sees only the Jira
  # projects they have a ProjectMembership for. Used to scope the Jira Tasks
  # views and the task lookups so a client can't reach another project's tasks.
  def visible_jira_projects
    scope = current_workspace.projects.active.where(external_type: "jira")
    return scope.order(:name) if current_user&.admin_or_owner?(current_workspace)

    scope.joins(:project_memberships)
         .where(project_memberships: { user_id: current_user&.id })
         .order(:name)
  end

  def current_role
    current_membership&.role
  end

  def require_admin!
    unless current_user&.admin_or_owner?(current_workspace)
      redirect_to root_path, alert: "You don't have permission to access this page."
    end
  end

  def require_employee!
    unless current_user&.at_least_employee?(current_workspace)
      redirect_to root_path, alert: "You don't have permission to access this page."
    end
  end

  # Jira tasks + their AI features are open to clients as well as employees.
  def require_client_or_employee!
    unless current_user&.client_or_employee?(current_workspace)
      redirect_to root_path, alert: "You don't have permission to access this page."
    end
  end

  def can_see_money?
    current_user&.can_see_money?(current_workspace)
  end

  # Gate a controller to a product (:time_hr / :workshop). When the user lacks
  # access, redirect to a product they CAN reach (never a loop, since the target
  # is their default accessible product).
  def require_product!(product)
    return if current_user&.can_access_product?(current_workspace, product)

    redirect_to product_landing_path, alert: "You don't have access to that part of the app."
  end

  # Used by the Jira/AI controllers: when a task/project lookup is scoped to the
  # user's visible projects and misses (e.g. a client guessing another project's
  # task id), send them back to the Jira board instead of a raw 404.
  def jira_record_not_found
    redirect_to jira_tasks_path, alert: "You don't have access to that."
  end
end
