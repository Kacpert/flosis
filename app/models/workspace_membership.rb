class WorkspaceMembership < ApplicationRecord
  belongs_to :user
  belongs_to :workspace

  before_destroy :destroy_project_memberships

  validates :user_id, uniqueness: { scope: :workspace_id }

  # A workspace must keep someone who can run it. Demoting or removing the
  # last administrator is refused rather than silently allowed, because the
  # recovery is a console session.
  def last_workspace_admin?
    return false unless workspace_admin?

    !workspace.workspace_memberships.where(workspace_admin: true).where.not(id: id).exists?
  end

  private

  def destroy_project_memberships
    ProjectMembership.where(user_id: user_id, project_id: workspace.project_ids).destroy_all
  end
end
