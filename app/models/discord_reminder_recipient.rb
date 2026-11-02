class DiscordReminderRecipient < ApplicationRecord
  belongs_to :workspace
  belongs_to :user
  has_many :discord_reminder_pings, dependent: :delete_all

  validates :discord_user_id, presence: true, format: { with: /\A\d+\z/, message: "must be a numeric Discord ID" }
  validates :min_daily_hours, numericality: { greater_than: 0 }
  validates :user_id, uniqueness: { scope: :workspace_id }

  scope :active, -> { where(active: true) }

  WORKING_DAYS_WINDOW = 3

  # True when, evaluated RIGHT NOW, the user logged under their daily threshold
  # on any eligible day in the window (last N working days, ending yesterday,
  # skipping approved-holiday days). Both the scheduler and the (delayed) message
  # job call this, so a message is only sent if the gap still exists at send time.
  def under_threshold_now?
    eligible = self.class.last_working_days(WORKING_DAYS_WINDOW).reject { |d| on_approved_holiday?(d) }
    return false if eligible.empty?

    min_seconds = (min_daily_hours * 3600).to_i
    eligible.any? { |day| logged_seconds(day) < min_seconds }
  end

  # Last N working days (Mon–Fri) ending yesterday; today is never included.
  def self.last_working_days(count)
    days = []
    day = Date.yesterday
    while days.size < count
      days << day unless day.saturday? || day.sunday?
      day -= 1.day
    end
    days
  end

  private

  def logged_seconds(day)
    workspace.time_entries.completed
      .where(user_id: user_id)
      .for_date(day)
      .sum(:duration_seconds)
  end

  def on_approved_holiday?(day)
    HolidayRequest
      .where(workspace_id: workspace_id, user_id: user_id, status: :approved)
      .where("start_date <= ? AND end_date >= ?", day, day)
      .exists?
  end
end
