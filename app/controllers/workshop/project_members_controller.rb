# The Users grid in Configuration. Managing who is on a project, and what they
# may do there, costs the Configuration permission — the same one that guards
# the keys, because the two are the same kind of power.
class Workshop::ProjectMembersController < Workshop::BaseController
  # dom_id, so the Turbo Stream replaces the same node the row rendered under.
  include ActionView::RecordIdentifier

  before_action { require_permission!(:configuration) }
  before_action :set_membership, only: %i[update destroy]

  # #create is added in Task 15, together with the dialogs that post to it.

  def update
    permission = params[:permission].to_s.to_sym
    return head :unprocessable_entity unless PermissionPreset::PERMISSIONS.include?(permission)

    @membership.update!(permission => params[:value] == "1")
    render turbo_stream: turbo_stream.replace(
      dom_id(@membership), partial: "workshop/configuration/user_row", locals: { membership: @membership }
    )
  end

  def destroy
    # A workspace admin's access comes from the flag, so removing the row would
    # change nothing. Refusing is honest; pretending is not.
    if @membership.user.workspace_admin?(current_workspace)
      return redirect_to workshop_configuration_path(tab: "users"),
                         alert: "An administrator's access does not come from this project."
    end

    name = @membership.user.name
    @membership.destroy
    redirect_to workshop_configuration_path(tab: "users"),
                flash: { clar_toast: "#{name} removed from #{current_workshop_project.name}." },
                status: :see_other
  end

  private

  def set_membership
    @membership = current_workshop_project.project_memberships.find(params[:id])
  end
end
