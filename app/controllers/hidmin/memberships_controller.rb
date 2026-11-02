# The people of one organization, from /hidmin: add someone by email, change
# what they hold, take them out, or send the invitation again. An organization
# always keeps an administrator (WorkspaceMembership#last_workspace_admin?).
class Hidmin::MembershipsController < Hidmin::BaseController
  before_action :set_workspace
  before_action :set_membership, only: %i[update destroy resend_invitation]

  def create
    invite = WorkspaceInvite.new(@workspace,
      name: params[:name], email_address: params[:email_address],
      workspace_admin: params[:workspace_admin] == "1", time_hr_access: params[:time_hr_access] == "1")

    if invite.save
      invite.deliver_later
      redirect_to hidmin_workspace_path(@workspace), notice: "#{invite.user.name} added and emailed."
    else
      redirect_to hidmin_workspace_path(@workspace), alert: invite.errors.full_messages.to_sentence
    end
  end

  def update
    attrs = { workspace_admin: params[:workspace_admin], time_hr_access: params[:time_hr_access] }
              .compact.transform_values { |value| value == "1" }

    if attrs[:workspace_admin] == false && @membership.last_workspace_admin?
      redirect_to hidmin_workspace_path(@workspace), alert: "#{@workspace.name} needs at least one administrator."
    else
      @membership.update!(attrs)
      redirect_to hidmin_workspace_path(@workspace), notice: "#{@membership.user.name} updated."
    end
  end

  def destroy
    if @membership.last_workspace_admin?
      redirect_to hidmin_workspace_path(@workspace), alert: "#{@workspace.name} needs at least one administrator.", status: :see_other
    else
      @membership.destroy!
      redirect_to hidmin_workspace_path(@workspace), notice: "#{@membership.user.name} removed from #{@workspace.name}.", status: :see_other
    end
  end

  # The welcome email again: its link sets a password and lasts a week, so
  # this is also how someone whose first link expired gets in.
  def resend_invitation
    InvitationMailer.welcome(@membership.user, @workspace).deliver_later
    redirect_to hidmin_workspace_path(@workspace), notice: "Invitation sent again to #{@membership.user.email_address}."
  end

  private

  def set_workspace
    @workspace = Workspace.find(params[:workspace_id])
  end

  def set_membership
    @membership = @workspace.workspace_memberships.find(params[:id])
  end
end
