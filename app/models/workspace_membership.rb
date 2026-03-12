class WorkspaceMembership < ApplicationRecord
  belongs_to :user
  belongs_to :workspace

  enum :role, { member: 0, admin: 1, owner: 2 }

  validates :user_id, uniqueness: { scope: :workspace_id }
end
