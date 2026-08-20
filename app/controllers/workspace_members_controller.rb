class WorkspaceMembersController < ApplicationController
  include WorkspaceScoped

  # stop_impersonating must never be product-gated: while impersonating a client
  # the session user is the client (Workshop-only), and gating would bounce the
  # "switch back" escape hatch to Jira Tasks before the admin is restored.
  before_action -> { require_product!(:time_hr) }, except: [ :stop_impersonating ]

  before_action :require_admin!, except: [ :stop_impersonating ]
  before_action :set_membership, only: %i[edit update destroy become]

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

    # The add form has no product checkboxes, so the schema defaults apply:
    # time_hr_access true, workshop_access false. That suits employees, but a
    # client role is Workshop-first — Time & HR has to be switched on
    # deliberately from the edit screen, never handed out by default.
    @membership = current_workspace.workspace_memberships.build(
      user: user,
      role: params[:role],
      time_hr_access: !%w[client workspace_client].include?(params[:role])
    )

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

    attrs = {
      role: params[:role],
      time_hr_access: params[:time_hr_access] == "1",
      workshop_access: params[:workshop_access] == "1"
    }
    if @membership.update(attrs)
      redirect_to workspace_members_path, notice: "Member updated."
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

  def become
    target_user = @membership.user

    if target_user == current_user
      redirect_to workspace_members_path, alert: "You're already logged in as this user."
      return
    end

    # Store admin session so we can switch back
    cookies.signed[:admin_session_id] = { value: Current.session.id, httponly: true, same_site: :lax }

    # Create a new session for the target user
    start_new_session_for(target_user)
    redirect_to root_path, notice: "Now viewing as #{target_user.name}"
  end

  def stop_impersonating
    admin_session = Session.find_by(id: cookies.signed[:admin_session_id])

    unless admin_session
      redirect_to root_path, alert: "No admin session found."
      return
    end

    # Restore admin session
    Current.session = admin_session
    cookies.signed.permanent[:session_id] = { value: admin_session.id, httponly: true, same_site: :lax }
    cookies.delete(:admin_session_id)

    redirect_to workspace_members_path, notice: "Switched back to your account."
  end

  private

  def set_membership
    @membership = current_workspace.workspace_memberships.find(params[:id])
  end
end
