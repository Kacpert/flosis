class WorkspaceMembership < ApplicationRecord
  belongs_to :user
  belongs_to :workspace

  before_destroy :destroy_project_memberships

  # employee/admin/owner — Time & HR + (flagged) Workshop access.
  # client            — Jira-Tasks-ONLY (a restricted Workshop guest, no Time & HR).
  # workspace_client  — FULL Workshop access WITH pricing, but NO Time & HR.
  enum :role, { employee: 0, admin: 1, owner: 2, client: 3, workspace_client: 4 }

  validates :user_id, uniqueness: { scope: :workspace_id }

  private

  def destroy_project_memberships
    ProjectMembership.where(user_id: user_id, project_id: workspace.project_ids).destroy_all
  end
end
