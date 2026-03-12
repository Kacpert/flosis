class TimeEntry < ApplicationRecord
  belongs_to :workspace
  belongs_to :user
  belongs_to :project, optional: true
  belongs_to :task, optional: true
  has_many :time_entry_tags, dependent: :destroy
  has_many :tags, through: :time_entry_tags

  validates :started_at, presence: true
  validate :stopped_at_after_started_at
  validate :no_duplicate_running_timer, on: :create

  before_save :calculate_duration, if: -> { stopped_at.present? }
  before_save :inherit_billable_from_project, if: -> { project_id_changed? && project.present? }
  before_save :set_hourly_rate, if: -> { stopped_at.present? }

  scope :running, -> { where(stopped_at: nil) }
  scope :completed, -> { where.not(stopped_at: nil) }
  scope :in_range, ->(from, to) { where(started_at: from..to) }
  scope :billable, -> { where(billable: true) }
  scope :for_date, ->(date) { where(started_at: date.beginning_of_day..date.end_of_day) }

  def running?
    stopped_at.nil?
  end

  def calculated_duration
    if running?
      (Time.current - started_at).to_i
    else
      duration_seconds
    end
  end

  def formatted_duration
    total = calculated_duration
    hours = total / 3600
    minutes = (total % 3600) / 60
    seconds = total % 60
    format("%02d:%02d:%02d", hours, minutes, seconds)
  end

  def effective_rate_cents
    hourly_rate_cents ||
      task&.hourly_rate_cents ||
      project&.effective_hourly_rate_cents ||
      workspace.default_hourly_rate_cents ||
      0
  end

  def billable_amount_cents
    return 0 unless billable?
    (duration_seconds / 3600.0 * effective_rate_cents).round
  end

  def billable_amount
    billable_amount_cents / 100.0
  end

  private

  def stopped_at_after_started_at
    return unless stopped_at.present? && started_at.present?
    errors.add(:stopped_at, "must be after start time") if stopped_at < started_at
  end

  def no_duplicate_running_timer
    return unless stopped_at.nil?
    if user&.time_entries&.running&.where(workspace: workspace)&.exists?
      errors.add(:base, "You already have a running timer in this workspace")
    end
  end

  def calculate_duration
    self.duration_seconds = (stopped_at - started_at).to_i
  end

  def inherit_billable_from_project
    self.billable = project.billable
  end

  def set_hourly_rate
    self.hourly_rate_cents = effective_rate_cents
  end
end
