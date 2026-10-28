# The new-project dialog in the project switcher. Creating a project is the
# workspace-wide privilege, not a per-project permission: there is no project
# yet for a permission to sit on.
class Workshop::ProjectsController < Workshop::BaseController
  before_action :require_admin!

  def create
    project = ProjectCreator.new(
      workspace: current_workspace,
      attributes: params.require(:project).permit(:name, :team, :github_repo),
      reuse_from: params[:reuse_from]&.permit!&.to_h,
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
end
