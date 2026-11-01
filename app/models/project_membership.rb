class ProjectMembership < ApplicationRecord
  belongs_to :project
  belongs_to :user
  has_many :rate_changes, dependent: :destroy

  validates :user_id, uniqueness: { scope: :project_id }

  # What this person may do in this project. The switches are the truth; the
  # role name is derived from them (see PermissionPreset).
  PERMISSIONS = PermissionPreset::PERMISSIONS

  # Rows that actually grant something. A row with all seven switches off is what
  # the backfill leaves an HR-only employee holding — the row is there so their
  # hours and their hourly rate attach to a project, not because they work in
  # its Workshop. Existence alone therefore answers no access question: it put
  # a Workshop in eight people's product switcher whose every page refused
  # them, and their projects in a switcher where every `can?` said false.
  scope :granting_anything, -> {
    where(PERMISSIONS.map { |permission| arel_table[permission].eq(true) }.reduce(:or))
  }

  # Whose access must never come from a row here: a workspace admin's. They
  # already hold everything in every project off the workspace flag, so the row
  # grants nothing while the flag is on, hands over whatever preset it carries
  # the day the flag comes off, and Configuration refuses to delete it in the
  # meantime — the mistake has no undo. The rule used to live only in a
  # dialog's `where.not`, so the service created exactly the row the grid
  # refuses.
  def self.refused_for?(user, workspace)
    user.present? && user.workspace_admin?(workspace)
  end

  # The same rule asked of a set, for the screens and services that pick people
  # by query rather than one at a time.
  def self.grantable(users, workspace)
    users.where.not(id: workspace.workspace_memberships.where(workspace_admin: true).select(:user_id))
  end

  # The switches that are on, in interface order.
  def granted
    PERMISSIONS.select { |permission| self[permission] }
  end

  def role_label
    PermissionPreset.label_for(granted)
  end

  # Applies a named preset. Deliberately assigns ALL seven switches, so this
  # clears what the preset does not grant rather than only adding to it.
  def apply_preset(label)
    assign_attributes(PermissionPreset.attributes_for(label))
    self
  end

  after_create :record_initial_rate
  after_update :record_rate_change, if: :saved_change_to_hourly_rate_cents?

  private

  def record_initial_rate
    rate_changes.create!(
      hourly_rate_cents: hourly_rate_cents,
      previous_rate_cents: nil,
      changed_by: Current.user,
      changed_at: Time.current
    )
  end

  def record_rate_change
    rate_changes.create!(
      hourly_rate_cents: hourly_rate_cents,
      previous_rate_cents: hourly_rate_cents_before_last_save,
      changed_by: Current.user,
      changed_at: Time.current
    )
  end
end
