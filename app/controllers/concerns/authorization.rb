module Authorization
  extend ActiveSupport::Concern

  included do
    helper_method :current_membership, :can_see_money?, :visible_jira_projects, :github_connection_problem?, :workshop_config_manager?
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

  # Jira projects the current user may see. Admins/owners and workspace_clients
  # (full Workshop access) see every Jira project in the workspace; everyone else
  # (employee, Jira-only client) sees only the Jira projects they have a
  # ProjectMembership for. Used to scope the Jira Tasks views and task lookups so
  # a restricted user can't reach another project's tasks.
  def visible_jira_projects
    scope = current_workspace.projects.active.where(external_type: "jira")
    if current_user&.admin_or_owner?(current_workspace) || current_user&.workspace_client_role?(current_workspace)
      return scope.order(:name)
    end

    scope.joins(:project_memberships)
         .where(project_memberships: { user_id: current_user&.id })
         .order(:name)
  end

  def current_role
    current_membership&.role
  end

  # Refuse the current request. An HTML page gets the familiar redirect + flash;
  # a JSON/XHR caller gets a status it can actually read. Redirecting a JSON
  # fetch used to send it to an HTML-only index, where the missing JSON template
  # raised ActionController::UnknownFormat — 681 stack traces in production for
  # requests that were merely unauthorized.
  def deny_access!(message, path, status: :forbidden)
    if request.format.json?
      render json: { error: message }, status: status
    else
      redirect_to path, alert: message
    end
  end

  def require_admin!
    unless current_user&.admin_or_owner?(current_workspace)
      deny_access!("You don't have permission to access this page.", root_path)
    end
  end

  # Gate for MANAGING the Workshop product (Configuration: integrations, AI,
  # briefing; Discord webhooks). Admins/owners AND workspace_clients pass — a
  # workspace_client can manage everything in the Workshop EXCEPT users. User
  # management stays behind require_admin! (workspace_client fails that), and the
  # Configuration "users" tab is hidden/blocked for them separately.
  def require_workshop_config_access!
    return if current_user&.admin_or_owner?(current_workspace)
    return if current_user&.workspace_client_role?(current_workspace)

    redirect_to root_path, alert: "You don't have permission to access this page."
  end

  def workshop_config_manager?
    current_user&.admin_or_owner?(current_workspace) ||
      current_user&.workspace_client_role?(current_workspace)
  end

  # Gate for the Time & HR working surfaces (time entries, timesheet, timer,
  # tags, holidays). Employees and up always pass; a workspace_client passes
  # only when an admin has switched their Time & HR product access on.
  def require_employee!
    unless current_user&.time_hr_member?(current_workspace)
      deny_access!("You don't have permission to access this page.", root_path)
    end
  end

  # Jira tasks + their AI features are open to clients as well as employees.
  def require_client_or_employee!
    unless current_user&.client_or_employee?(current_workspace)
      deny_access!("You don't have permission to access this page.", root_path)
    end
  end

  # Gate for endpoints that serve BOTH products, so neither product gate fits:
  # the timer bar's Jira task picker is the case that matters — picking the
  # ticket you're logging hours against is a Time & HR action, but the data is
  # Jira's. Every role in the workspace may do it, including the Jira-only
  # `client` and a `workspace_client` who has Time & HR switched on. The real
  # boundary stays visible_jira_projects: a non-admin still only reaches the
  # projects they are a member of.
  def require_workspace_member!
    return if current_membership.present?

    deny_access!("You don't have permission to access this page.", root_path)
  end

  # Gate AI/workshop-tooling endpoints (e.g. brief chat) to real workshop
  # members. Deliberately does NOT reuse require_product!(:workshop) /
  # User#can_access_workshop? — that predicate returns true for the Jira-only
  # `client` role (they are Jira-Tasks-only, which lives in the Workshop
  # product), and routes like /jira_tasks/* are client-allowed by
  # redirect_clients_to_jira. Reusing it here would let a Jira-only client spawn
  # an AI chat session. So this helper excludes the `client` role and requires
  # the workshop_access flag — BUT a `workspace_client` (full Workshop access)
  # is a real workshop member and always passes.
  def require_workshop_member!
    membership = current_user&.workspace_memberships&.find_by(workspace: current_workspace)
    return if membership&.workspace_client?
    return if membership && !membership.client? && membership.workshop_access

    deny_access!("Not authorized", root_path)
  end

  def can_see_money?
    current_user&.can_see_money?(current_workspace)
  end

  # Gate a controller to a product (:time_hr / :workshop). When the user lacks
  # access, redirect to a product they CAN reach (never a loop, since the target
  # is their default accessible product).
  def require_product!(product)
    return if current_user&.can_access_product?(current_workspace, product)

    deny_access!("You don't have access to that part of the app.", product_landing_path)
  end

  # Used by the Jira/AI controllers: when a task/project lookup is scoped to the
  # user's visible projects and misses (e.g. a client guessing another project's
  # task id), send them back to the Jira board instead of a raw 404.
  def jira_record_not_found
    deny_access!("You don't have access to that.", jira_tasks_path, status: :not_found)
  end
end
