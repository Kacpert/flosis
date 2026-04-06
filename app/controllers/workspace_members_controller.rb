class WorkspaceMembersController < ApplicationController
  include WorkspaceScoped

  before_action :require_admin!
  before_action :set_membership, only: %i[edit update destroy]

  def index
    @memberships = current_workspace.workspace_memberships
      .includes(user: { project_memberships: :project })
      .order("users.name")
  end

  def new
    @membership = current_workspace.workspace_memberships.build
  end

  def create
    user = User.find_by(email_address: params[:email_address]&.strip&.downcase)
    new_user = user.nil?

    if new_user
      temp_password = SecureRandom.base58(24)
      user = User.new(
        name: params[:name],
        email_address: params[:email_address],
        password: temp_password,
        password_confirmation: temp_password
      )

      unless user.save
        flash.now[:alert] = user.errors.full_messages.to_sentence
        @membership = current_workspace.workspace_memberships.build
        return render :new, status: :unprocessable_entity
      end
    end

    if user.member_of?(current_workspace)
      flash.now[:alert] = "This user is already a member of this workspace."
      @membership = current_workspace.workspace_memberships.build
      return render :new, status: :unprocessable_entity
    end

    @membership = current_workspace.workspace_memberships.build(user: user, role: params[:role])

    if @membership.save
      if new_user
        InvitationMailer.welcome(user, current_workspace).deliver_later
      else
        InvitationMailer.added_to_workspace(user, current_workspace).deliver_later
      end
      redirect_to workspace_members_path, notice: "#{user.name} added as #{@membership.role}. Invitation email sent."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    if @membership.owner? && !current_membership.owner?
      redirect_to workspace_members_path, alert: "Only owners can modify owner memberships."
      return
    end

    if @membership.update(role: params[:role])
      redirect_to workspace_members_path, notice: "Role updated."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    if @membership.user == current_user
      redirect_to workspace_members_path, alert: "You can't remove yourself."
      return
    end

    if @membership.owner? && !current_membership.owner?
      redirect_to workspace_members_path, alert: "Only owners can remove owners."
      return
    end

    name = @membership.user.name
    @membership.destroy
    redirect_to workspace_members_path, notice: "#{name} removed.", status: :see_other
  end

  private

  def set_membership
    @membership = current_workspace.workspace_memberships.find(params[:id])
  end
end
