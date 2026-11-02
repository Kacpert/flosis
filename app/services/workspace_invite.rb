# Puts a person into a workspace by email address, the way Flosis staff
# onboard a client from /hidmin. An address no account has gets one, with a
# random password and the welcome email, whose link sets the real password; an
# address that has an account keeps it as it is, name included, and gets the
# "added to" email. The workspace may still be unsaved: a new organization and
# its first administrator are saved together, or neither is.
class WorkspaceInvite
  include ActiveModel::Model

  attr_reader :workspace, :user, :membership

  def initialize(workspace, name:, email_address:, workspace_admin: false, time_hr_access: true)
    super()
    @workspace = workspace
    email_address = email_address.to_s.strip.downcase
    @user = User.find_by(email_address: email_address) || build_user(name, email_address)
    @membership = WorkspaceMembership.new(workspace: workspace, user: @user,
                                          workspace_admin: workspace_admin, time_hr_access: time_hr_access)
  end

  validate :user_is_valid
  validate :not_a_member_yet

  def new_user?
    @user.new_record?
  end

  # Saves the account (when new) and the membership. Raises
  # ActiveRecord::RecordInvalid, so a caller saving the workspace in the same
  # transaction rolls both back.
  def save!
    raise ActiveRecord::RecordInvalid unless valid?

    @created_user = new_user?
    WorkspaceMembership.transaction do
      user.save! if new_user?
      membership.save!
    end
  end

  def save
    save!
    true
  rescue ActiveRecord::RecordInvalid => e
    errors.add(:base, e.record.errors.full_messages.to_sentence) if e.record
    false
  end

  # After the transaction, so the job never looks for rows not yet committed.
  def deliver_later
    InvitationMailer.public_send(@created_user ? :welcome : :added_to_workspace, user, workspace).deliver_later
  end

  private

  def build_user(name, email_address)
    password = SecureRandom.base58(24)
    User.new(name: name.to_s.strip, email_address: email_address, password: password, password_confirmation: password)
  end

  def user_is_valid
    return if user.persisted? || user.valid?

    user.errors.each { |error| errors.add(error.attribute, error.message) }
  end

  def not_a_member_yet
    return unless user.persisted? && workspace.persisted? && user.member_of?(workspace)

    errors.add(:base, "#{user.name} is already a member of #{workspace.name}.")
  end
end
