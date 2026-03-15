class Task < ApplicationRecord
  belongs_to :project
  has_many :time_entries, dependent: :nullify

  enum :status, { active: 0, done: 1 }

  scope :jira_synced, -> { where(external_type: "jira") }
  scope :local_only, -> { where(external_type: [nil, ""]) }

  validates :name, presence: true, uniqueness: { scope: :project_id }
end
