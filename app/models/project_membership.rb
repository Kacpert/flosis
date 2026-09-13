class ProjectMembership < ApplicationRecord
  belongs_to :project
  belongs_to :user
  has_many :rate_changes, dependent: :destroy

  validates :user_id, uniqueness: { scope: :project_id }

  # What this person may do in this project. The switches are the truth; the
  # role name is derived from them (see PermissionPreset).
  PERMISSIONS = PermissionPreset::PERMISSIONS

  # The switches that are on, in interface order.
  def granted
    PERMISSIONS.select { |permission| self[permission] }
  end

  def role_label
    PermissionPreset.label_for(granted)
  end

  # Applies a named preset. Deliberately assigns ALL six switches, so this
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
