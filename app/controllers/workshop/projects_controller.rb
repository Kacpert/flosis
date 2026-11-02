# The new-project dialog in the project switcher. Creating a project is the
# workspace-wide privilege, not a per-project permission: there is no project
# yet for a permission to sit on.
class Workshop::ProjectsController < Workshop::BaseController
  skip_before_action :require_current_project! # the first project is made with none
  before_action :require_admin!

  def create
    project = ProjectCreator.new(
      workspace: current_workspace,
      attributes: params.require(:project).permit(:name, :team, :external_reference, :jira_site, :jira_email,
                                                  :jira_api_token, :github_repo, :github_token, :anthropic_api_key)
                        .to_h.compact_blank,
      reuse_from: reuse_from,
      member_ids: params[:user_ids],
      preset: params[:preset]
    ).call

    # Land on the new project's Configuration: it has no keys yet, and that is
    # where the person was heading next anyway.
    session[:workshop_project_id] = project.id
    redirect_to workshop_configuration_path(tab: "integrations"),
                flash: { clar_toast: "#{project.name} created." }
  rescue ActiveRecord::RecordInvalid => e
    redirect_back fallback_location: workshop_pipeline_path,
                  alert: e.record.errors.full_messages.to_sentence
  end

  private

  # Only the integrations whose columns the service actually copies, named
  # rather than permitted wholesale — and only when the parameter arrived as a
  # hash at all, since `reuse_from=1` used to make `permit!` a NoMethodError and
  # the create a 500.
  def reuse_from
    posted = params[:reuse_from]
    return {} unless posted.respond_to?(:permit)

    posted.permit(*ProjectCreator::CREDENTIALS.keys).to_h
  end
end
