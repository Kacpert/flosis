class User < ApplicationRecord
  has_secure_password
  has_many :sessions, dependent: :destroy
  has_many :workspace_memberships, dependent: :destroy
  has_many :workspaces, through: :workspace_memberships
  has_many :time_entries, dependent: :restrict_with_error
  has_many :project_memberships, dependent: :destroy

  normalizes :email_address, with: ->(e) { e.strip.downcase }

  validates :name, presence: true
  validates :email_address, presence: true, uniqueness: true, format: { with: URI::MailTo::EMAIL_REGEXP }

  def running_timer(workspace)
    time_entries.where(workspace: workspace, stopped_at: nil).first
  end

  def member_of?(workspace)
    workspace_memberships.exists?(workspace: workspace)
  end

  def membership_for(workspace)
    workspace_memberships.find_by(workspace: workspace)
  end

  def role_in(workspace)
    membership_for(workspace)&.role
  end

  def admin_or_owner?(workspace)
    role = role_in(workspace)
    role == "admin" || role == "owner"
  end

  def at_least_employee?(workspace)
    role = role_in(workspace)
    role == "employee" || role == "admin" || role == "owner"
  end

  def client_role?(workspace)
    role_in(workspace) == "client"
  end

  def can_see_money?(workspace)
    admin_or_owner?(workspace)
  end
end
