class WorkspaceMembership < ApplicationRecord
  belongs_to :user
  belongs_to :workspace

  enum :role, { employee: 0, admin: 1, owner: 2, client: 3 }

  validates :user_id, uniqueness: { scope: :workspace_id }
end
