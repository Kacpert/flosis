module Authorization
  extend ActiveSupport::Concern

  included do
    helper_method :current_membership, :current_project_access, :can?,
                  :workspace_admin?, :visible_jira_projects,
                  :github_connection_problem?
  end

  private

  # True when a GitHub token is configured but the last health check failed —
  # drives the admin-only error banner. Reads the project without selecting
  # one: this runs on every page in the HR layout, and a predicate that writes
  # to the session would make viewing a timesheet set the viewer's Workshop
  # project.
  def github_connection_problem?
    project = resolved_workshop_project
    project&.github_token.present? && project.github_status_ok == false
  end

  def current_membership
    @current_membership ||= current_user&.membership_for(current_workspace)
  end

  # The workspace-wide privilege: creating projects, the HR module, the
  # employee directory.
  def workspace_admin?
    current_user&.workspace_admin?(current_workspace) || false
  end

  # Access to the Workshop project currently being viewed. The admin privilege
  # is handed in from the workspace: with no project yet, ProjectAccess cannot
  # find one to ask, and a new organization's administrator was locked out of
  # the Workshop, where the first project is created.
  def current_project_access
    @current_project_access ||= ProjectAccess.new(current_user, current_workshop_project, workspace_admin: workspace_admin?)
  end

  def can?(permission)
    current_project_access.can?(permission)
  end

  # Passes when the person holds ANY of the named permissions. A page that
  # serves two audiences — the process page carries both ticket flow and the
  # automations — should not demand both.
  def require_permission!(*permissions)
    return if permissions.any? { |permission| can?(permission) }

    deny_access!("You don't have permission to access this page.", workshop_landing_path)
  end

  # Permission on a NAMED project, for actions that operate on a project taken
  # from the params rather than on the session's current one. `can?` answers
  # about current_workshop_project, so using it to guard those actions asks
  # about the wrong project and hands someone Configuration over a project they
  # merely have Tasks on.
  def require_permission_on!(project, *permissions)
    access = ProjectAccess.new(current_user, project)
    return if project && permissions.any? { |permission| access.can?(permission) }

    deny_access!("You don't have permission to access this page.", workshop_landing_path)
  end

  # Standing in the project, without naming a permission. The Workshop subtree
  # needs this; each area below it then asks for the permission it actually
  # uses. Gating the whole subtree on :tasks instead would shut someone who
  # holds only Reporting out of the reports they were deliberately granted.
  def require_project_member!
    return if current_project_access.member?

    deny_access!("You don't have permission to access this page.", product_landing_path)
  end

  # Jira projects the current user may WORK in. Admins see every one; everyone
  # else sees the projects where their membership grants Tasks.
  #
  # `.in_workshop` for the same reason as WorkspaceScoped#workshop_projects: a
  # project kept out of Flosis must not offer a board to work tickets on, even
  # if it still carries Jira credentials from before it was hidden.
  def visible_jira_projects
    scope = current_workspace.projects.active.in_workshop.where(external_type: "jira")
    return scope.order(:name) if workspace_admin?

    scope.joins(:project_memberships)
         .where(project_memberships: { user_id: current_user&.id, tasks: true })
         .order(:name)
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

  # The workspace-wide privilege: creating projects, the HR module, the
  # employee directory.
  def require_admin!
    return if workspace_admin?

    deny_access!("You don't have permission to access this page.", root_path)
  end

  # The HR working surfaces: time entries, timesheet, timer, tags, holidays.
  def require_employee!
    return if current_user&.can_access_time_hr?(current_workspace)

    deny_access!("You don't have permission to access this page.", root_path)
  end

  # The timer bar's Jira task picker belongs to neither product. Choosing which
  # ticket you are logging hours against is an HR action that happens to read
  # Jira's data, so an employee who was never invited to the Workshop must keep
  # it. The real boundary stays available_projects: you only ever see the
  # projects you are on.
  def require_time_hr_or_project_member!
    return if current_user&.can_access_time_hr?(current_workspace)
    return if available_projects.exists?

    deny_access!("You don't have permission to access this page.", root_path)
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
