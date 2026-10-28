# The Users grid in Configuration. Managing who is on a project, and what they
# may do there, costs the Configuration permission — the same one that guards
# the keys, because the two are the same kind of power.
class Workshop::ProjectMembersController < Workshop::BaseController
  # dom_id, so the Turbo Stream replaces the same node the row rendered under.
  include ActionView::RecordIdentifier

  before_action { require_permission!(:configuration) }
  before_action :set_membership, only: %i[update destroy]

  # Both dialogs post here: "Invite" sends a name and an address, "Add from
  # other project" sends the chips it ticked. Either way the switches the
  # dialog was showing come along, so what gets saved is what was on screen.
  def create
    people = params[:email_address].present? ? [ invited_user ].compact : picked_users.to_a
    return redirect_to(workshop_configuration_path(tab: "users"), alert: @error) if @error

    people.each { |user| add_to_project(user) }

    redirect_to workshop_configuration_path(tab: "users"),
                flash: { clar_toast: added_toast(people) }
  end

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

  # The preset is only where the switches started. Whoever is inviting can
  # flip any of them before submitting, so the posted switches win and the
  # preset is the fallback for the ones the form did not send.
  def add_to_project(user)
    membership = current_workshop_project.project_memberships.find_or_initialize_by(user: user)
    membership.apply_preset(params[:preset].to_s)

    tuned = params[:permissions]
    if tuned.present?
      PermissionPreset::PERMISSIONS.each do |permission|
        membership[permission] = tuned[permission.to_s] == "1" if tuned.key?(permission.to_s)
      end
    end

    membership.save!
  end

  # People already in this workspace, picked from the chips. Scoped to the
  # workspace so a guessed id cannot pull in a stranger's account.
  def picked_users
    User.where(id: Array(params[:user_ids]))
        .joins(:workspace_memberships)
        .where(workspace_memberships: { workspace_id: current_workspace.id })
  end

  # An invitation by address. A Workshop invitation deliberately grants no HR
  # access: the two directories are separate, and a form that quietly set both
  # is the confusion this work exists to remove. An address that already has
  # an account joins the project with the account it has.
  def invited_user
    address = params[:email_address].to_s.strip.downcase
    user = User.find_by(email_address: address)

    if user.nil?
      password = SecureRandom.base58(24)
      user = User.new(name: params[:name], email_address: address,
                      password: password, password_confirmation: password)
      unless user.save
        @error = user.errors.full_messages.to_sentence
        return nil
      end
    end

    unless user.member_of?(current_workspace)
      current_workspace.workspace_memberships.create!(
        user: user, time_hr_access: false, workspace_admin: false
      )
      InvitationMailer.welcome(user, current_workspace).deliver_later
    end

    user
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
