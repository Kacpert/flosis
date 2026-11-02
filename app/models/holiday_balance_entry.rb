class HolidayBalanceEntry < ApplicationRecord
  belongs_to :user
  belongs_to :workspace
  belongs_to :holiday_request, optional: true
  belongs_to :created_by, class_name: "User", optional: true

  enum :entry_type, { yearly_grant: 0, admin_adjustment: 1, deduction: 2, reversal: 3 }

  validates :days, presence: true, numericality: { other_than: 0 }
  validate :note_required_for_admin_adjustment

  private

  def note_required_for_admin_adjustment
    if admin_adjustment? && note.blank?
      errors.add(:note, "is required for admin adjustments")
    end
  end
end
