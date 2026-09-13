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

    # The directory grants HR access and, optionally, the workspace privilege.
    # Nothing here touches any project: Workshop standing is granted per
    # project, in Configuration > Users.
    @membership = current_workspace.workspace_memberships.build(
      user: user,
      time_hr_access: params[:time_hr_access] != "0",
      workspace_admin: params[:workspace_admin] == "1"
    )

    if @membership.save
      mailer = new_user ? :welcome : :added_to_workspace
      InvitationMailer.public_send(mailer, user, current_workspace).deliver_later
      redirect_to workspace_members_path, notice: "#{user.name} added. Invitation email sent."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    if @membership.last_workspace_admin? && params[:workspace_admin] != "1"
      redirect_to workspace_members_path, alert: "A workspace needs at least one administrator."
      return
    end

    attrs = {
      time_hr_access: params[:time_hr_access] == "1",
      workspace_admin: params[:workspace_admin] == "1"
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

    if @membership.last_workspace_admin?
      redirect_to workspace_members_path, alert: "A workspace needs at least one administrator."
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
