class ProfilesController < ApplicationController
  include WorkspaceScoped

  # update re-renders :show when the form is refused, and that template needs
  # the access rows just as much as show itself does.
  before_action :load_access_rows

  def show
  end

  def update
    if params[:user][:password].present?
      unless current_user.authenticate(params[:user][:current_password])
        current_user.errors.add(:current_password, "is incorrect")
        render :show, status: :unprocessable_entity
        return
      end
    end

    user_params = params.require(:user).permit(:name, :email_address, :timezone)

    # Handle password change
    if params[:user][:password].present?
      user_params[:password] = params[:user][:password]
      user_params[:password_confirmation] = params[:user][:password_confirmation]
    end

    if current_user.update(user_params)
      redirect_to profile_path, notice: "Profile updated."
    else
      render :show, status: :unprocessable_entity
    end
  end

  private

  # One row per project this person can reach, each able to answer what they
  # may do there. workshop_projects and not the workspace's own projects: every
  # permission on this card is enforced against current_workshop_project, which
  # comes from that scope, so any other row set promises access no Workshop
  # screen can be pointed at — an archived project most of all.
  def load_access_rows
    @memberships_without_access = false
    return @access_rows = [] unless current_workspace

    # The admin privilege is workspace-wide, so it is answered once here and
    # handed to every row — the way the Users grid hands `locked` to its row
    # partial. Asking per row cost a workspace_memberships query seven times
    # over for each project on the card.
    admin = workspace_admin?

    @access_rows = workshop_projects.map do |project|
      ProjectAccess.new(current_user, project, workspace_admin: admin)
    end

    # A row here is every ACTIVE project the person holds SOMETHING on, so a
    # membership on an active project with no row behind it can only be one
    # that grants nothing — the all-off row an HR-only employee holds so their
    # hours and their hourly rate attach to a project. Without that distinction
    # the empty card told eight of the fifteen people on production they were
    # on no project, while they were on two.
    @memberships_without_access = @access_rows.empty? && !admin &&
                                  ProjectMembership.exists?(
                                    user_id: current_user&.id,
                                    project: current_workspace.projects.active
                                  )
  end
end
