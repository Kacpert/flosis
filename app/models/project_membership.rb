class ProjectMembership < ApplicationRecord
  belongs_to :project
  belongs_to :user
  has_many :rate_changes, dependent: :destroy

  validates :user_id, uniqueness: { scope: :project_id }
end
