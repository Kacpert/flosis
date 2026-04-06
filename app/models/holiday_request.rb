class HolidayRequest < ApplicationRecord
  belongs_to :user
  belongs_to :workspace
  belongs_to :reviewed_by, class_name: "User", optional: true
  has_many :holiday_balance_entries

  enum :status, { pending: 0, approved: 1, cancelled: 2 }

  validates :start_date, :end_date, presence: true
  validate :end_date_after_start_date
  validate :start_date_not_in_past, on: :create
  validate :no_overlapping_requests, on: :create
  validate :sufficient_balance, on: :create

  before_validation :compute_business_days

  scope :active, -> { where(status: [:pending, :approved]) }

  def approve!(admin)
    transaction do
      update!(
        status: :approved,
        reviewed_by: admin,
        reviewed_at: Time.current
      )
      holiday_balance_entries.create!(
        user: user,
        workspace: workspace,
        entry_type: :deduction,
        days: -business_days
      )
    end
    HolidayRequestMailer.approved(self).deliver_later
  end

  def cancel!(admin)
    was_approved = approved?
    transaction do
      update!(
        status: :cancelled,
        reviewed_by: admin,
        reviewed_at: Time.current
      )
      if was_approved
        holiday_balance_entries.create!(
          user: user,
          workspace: workspace,
          entry_type: :reversal,
          days: business_days
        )
      end
    end
    HolidayRequestMailer.cancelled(self).deliver_later
  end

  private

  def compute_business_days
    return unless start_date.present? && end_date.present? && start_date <= end_date
    self.business_days = (start_date..end_date).count { |d| !d.saturday? && !d.sunday? }
  end

  def end_date_after_start_date
    return unless start_date.present? && end_date.present?
    if end_date < start_date
      errors.add(:end_date, "must be on or after start date")
    end
  end

  def start_date_not_in_past
    return unless start_date.present?
    if start_date < Date.current
      errors.add(:start_date, "can't be in the past")
    end
  end

  def no_overlapping_requests
    return unless start_date.present? && end_date.present?
    overlapping = HolidayRequest
      .where(user: user, workspace: workspace)
      .where(status: [:pending, :approved])
      .where("start_date <= ? AND end_date >= ?", end_date, start_date)
    overlapping = overlapping.where.not(id: id) if persisted?
    if overlapping.exists?
      errors.add(:base, "overlaps with an existing request")
    end
  end

  def sufficient_balance
    return unless user.present? && workspace.present? && business_days.present?
    pending_days = HolidayRequest
      .where(user: user, workspace: workspace, status: :pending)
      .sum(:business_days)
    available = user.holiday_balance(workspace) - pending_days
    if available < business_days
      errors.add(:base, "insufficient holiday balance (#{available} days available, #{business_days} requested)")
    end
  end
end
