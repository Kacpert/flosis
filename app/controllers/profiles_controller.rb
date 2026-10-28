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
  # may do there. A workspace admin reaches every project without a membership
  # row, so their list comes from the workspace rather than from memberships.
  def load_access_rows
    return @access_rows = [] unless current_workspace

    projects = if workspace_admin?
      current_workspace.projects.order(:name)
    else
      current_workspace.projects
                       .where(id: ProjectMembership.where(user_id: current_user.id).select(:project_id))
                       .order(:name)
    end

    @access_rows = projects.map { |project| ProjectAccess.new(current_user, project) }
  end
end
