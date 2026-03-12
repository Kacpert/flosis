class Task < ApplicationRecord
  belongs_to :project
  has_many :time_entries, dependent: :nullify

  enum :status, { active: 0, done: 1 }

  validates :name, presence: true, uniqueness: { scope: :project_id }

  def effective_hourly_rate_cents
    hourly_rate_cents || project.effective_hourly_rate_cents
  end
end
