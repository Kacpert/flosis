class WorkspaceMembership < ApplicationRecord
  belongs_to :user
  belongs_to :workspace

  before_destroy :destroy_project_memberships

  enum :role, { employee: 0, admin: 1, owner: 2, client: 3 }

  validates :user_id, uniqueness: { scope: :workspace_id }

  private

  def destroy_project_memberships
    ProjectMembership.where(user_id: user_id, project_id: workspace.project_ids).destroy_all
  end
end
