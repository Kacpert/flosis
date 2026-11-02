class Hidmin::DashboardController < Hidmin::BaseController
  def show
    @workspace_count = Workspace.count
    @user_count = User.count
    @project_count = Project.active.count
    @active_user_count = Session.where(created_at: 7.days.ago..).distinct.count(:user_id)
    @newest_workspaces = Workspace.order(created_at: :desc).limit(5)
    @newest_users = User.order(created_at: :desc).limit(5)
  end
end
