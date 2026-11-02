# Organizations are workspaces. A new one is saved together with its first
# administrator, or not at all: an organization nobody can run would need a
# console session to fix.
class Hidmin::WorkspacesController < Hidmin::BaseController
  before_action :set_workspace, only: %i[show update]

  def index
    @workspaces = Workspace.order(:name)
    @member_counts = WorkspaceMembership.group(:workspace_id).count
    @project_counts = Project.active.group(:workspace_id).count
  end

  def show
    load_members
  end

  def new
    @workspace = Workspace.new(workshop_enabled: true)
    @invite = WorkspaceInvite.new(@workspace, name: "", email_address: "")
  end

  def create
    @workspace = Workspace.new(workspace_params)
    @invite = WorkspaceInvite.new(@workspace, **admin_params, workspace_admin: true)

    if [ @workspace.valid?, @invite.valid? ].all?
      Workspace.transaction do
        @workspace.save!
        @invite.save!
      end
      @invite.deliver_later
      redirect_to hidmin_workspace_path(@workspace), notice: "#{@workspace.name} created. #{@invite.user.name} is its administrator and has been emailed."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def update
    if @workspace.update(workspace_params)
      redirect_to hidmin_workspace_path(@workspace), notice: "Saved."
    else
      load_members
      render :show, status: :unprocessable_entity
    end
  end

  private

  def set_workspace
    @workspace = Workspace.find(params[:id])
  end

  def load_members
    @memberships = @workspace.workspace_memberships.includes(:user).order("users.name").references(:user)
    @projects = @workspace.projects.order(:archived, :name)
    @new_member = WorkspaceInvite.new(@workspace, name: "", email_address: "")
  end

  def workspace_params
    params.require(:workspace).permit(:name, :workshop_enabled, :clients_enabled)
  end

  def admin_params
    admin = params.fetch(:admin, {}).permit(:name, :email_address, :time_hr_access)
    { name: admin[:name], email_address: admin[:email_address], time_hr_access: admin[:time_hr_access] == "1" }
  end
end
