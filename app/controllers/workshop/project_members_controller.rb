# The Users grid in Configuration. Managing who is on a project, and what they
# may do there, costs the Configuration permission — the same one that guards
# the keys, because the two are the same kind of power.
class Workshop::ProjectMembersController < Workshop::BaseController
  # dom_id, so the Turbo Stream replaces the same node the row rendered under.
  include ActionView::RecordIdentifier

  # Said by create and by update as well as by destroy, because all three are
  # declining the same thing: a row that would hold nothing.
  ADMIN_REFUSAL = "An administrator's access does not come from this project.".freeze

  before_action { require_permission!(:configuration) }
  before_action :set_membership, only: %i[update destroy]

  # Both dialogs post here: "Invite" sends a name and an address, "Add from
  # other project" sends the chips it ticked. Either way the switches the
  # dialog was showing come along, so what gets saved is what was on screen.
  def create
    people = params[:email_address].present? ? [ invited_user ].compact : picked_users.to_a
    return refuse(@error) if @error

    # Nothing on either dialog says it edits anyone, so it must not: the two
    # people this screen turns away are refused before a membership is created
    # and before any mail goes out.
    reason = refusal_for(people)
    return refuse(reason) if reason

    people.each do |user|
      welcome_to_workspace(user)
      add_to_project(user)
    end
    return refuse(@error) if @error

    redirect_to workshop_configuration_path(tab: "users"),
                flash: { clar_toast: added_toast(people) }
  end

  def update
    permission = params[:permission].to_s.to_sym
    return head :unprocessable_entity unless PermissionPreset::PERMISSIONS.include?(permission)

    # The same refusal destroy makes, for the same reason: the flag already
    # grants all six, so this would store a value that is ignored today and
    # takes effect the day the flag comes off. The grid renders these switches
    # disabled, so only a hand-rolled request gets here.
    return refuse(ADMIN_REFUSAL) if ProjectMembership.refused_for?(@membership.user, current_workspace)

    # save rather than save!: a switch that cannot be written is a flash the
    # person can read, not a 500 and a row stuck half-flipped on screen.
    unless @membership.update(permission => params[:value] == "1")
      return refuse(@membership.errors.full_messages.to_sentence)
    end

    render turbo_stream: turbo_stream.replace(
      dom_id(@membership),
      # Never locked: an administrator's row was refused two lines up.
      partial: "workshop/configuration/user_row", locals: { membership: @membership, locked: false }
    )
  end

  def destroy
    # A workspace admin's access comes from the flag, so removing the row would
    # change nothing. Refusing is honest; pretending is not.
    return refuse(ADMIN_REFUSAL) if ProjectMembership.refused_for?(@membership.user, current_workspace)

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

  def refuse(message)
    redirect_to workshop_configuration_path(tab: "users"), alert: message
  end

  # Who this screen will not add, and why in those words. An administrator's
  # row would hold nothing and destroy would then refuse to delete it, so the
  # mistake has no undo — the rule itself lives on ProjectMembership, because
  # ProjectCreator has to make the same refusal. Someone already here has
  # permissions, and they belong to the grid rather than to a dialog whose
  # button says "add" — re-running a preset over them silently grants and
  # revokes in one go.
  def refusal_for(people)
    return ADMIN_REFUSAL if people.any? { |user| ProjectMembership.refused_for?(user, current_workspace) }

    existing = current_workshop_project.project_memberships.where(user: people).includes(:user).first
    already_on_project(existing.user) if existing
  end

  def already_on_project(user)
    "#{user.name} is already on #{current_workshop_project.name} — " \
      "their permissions are the switches on their row in the grid."
  end

  # The preset is only where the switches started. Whoever is inviting can
  # flip any of them before submitting, so the posted switches win and the
  # preset is the fallback for the ones the form did not send.
  def add_to_project(user)
    membership = current_workshop_project.project_memberships.new(user: user)
    membership.apply_preset(params[:preset].to_s)

    tuned = params[:permissions]
    if tuned.present?
      PermissionPreset::PERMISSIONS.each do |permission|
        membership[permission] = tuned[permission.to_s] == "1" if tuned.key?(permission.to_s)
      end
    end

    # The row is new by now — refusal_for turned away everyone who already had
    # one. What is left is the double submit, where the second request loses to
    # the unique index (or to its own validation, the only one on the model);
    # the row the first one made is the right answer, so say so instead of 500.
    @error = already_on_project(user) unless membership.save
  rescue ActiveRecord::RecordNotUnique
    @error = already_on_project(user)
  end

  # People already in this workspace, picked from the chips. Scoped to the
  # workspace so a guessed id cannot pull in a stranger's account.
  def picked_users
    User.where(id: Array(params[:user_ids]))
        .joins(:workspace_memberships)
        .where(workspace_memberships: { workspace_id: current_workspace.id })
  end

  # An invitation by address resolves to an account and nothing more: joining
  # the workspace and the mail that announces it wait until the refusals have
  # run, so a refused invitation leaves no trace. An address that already has
  # an account joins the project with the account it has.
  def invited_user
    address = params[:email_address].to_s.strip.downcase
    user = User.find_by(email_address: address)
    @new_account = user.nil?
    return user unless @new_account

    password = SecureRandom.base58(24)
    user = User.new(name: params[:name], email_address: address,
                    password: password, password_confirmation: password)
    return user if user.save

    @error = user.errors.full_messages.to_sentence
    nil
  end

  # A Workshop invitation deliberately grants no HR access: the two directories
  # are separate, and a form that quietly set both is the confusion this work
  # exists to remove.
  #
  # welcome carries a week-long password-set link, so it is only ever for an
  # account that has no password yet. Anyone else is told they were added —
  # the same choice WorkspaceMembersController#create makes. Already in the
  # workspace means no mail of either kind: the design adds a known person
  # directly, and nothing about the workspace changed.
  def welcome_to_workspace(user)
    return if user.member_of?(current_workspace)

    current_workspace.workspace_memberships.create!(
      user: user, time_hr_access: false, workspace_admin: false
    )
    InvitationMailer.public_send(@new_account ? :welcome : :added_to_workspace,
                                 user, current_workspace).deliver_later
  end

  # Naming the one person reads better than counting them, and an empty chip
  # selection is a no-op rather than "0 people added".
  def added_toast(people)
    case people.size
    when 0 then "Nobody selected."
    when 1 then "#{people.first.name} added to #{current_workshop_project.name}."
    else "#{people.size} people added to #{current_workshop_project.name}."
    end
  end
end
