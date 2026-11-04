# flosis_staff (a column, so flosis_staff? comes from Active Record) marks the
# people of Flosis the company, who keep the design library. It is not a
# workspace role: a workspace admin is not staff. FlosisStaff sets it.
class User < ApplicationRecord
  has_secure_password
  include Holidayable

  generates_token_for :invitation, expires_in: 1.week do
    password_salt&.last(10)
  end
  has_many :sessions, dependent: :destroy
  has_many :workspace_memberships, dependent: :destroy
  has_many :workspaces, through: :workspace_memberships
  has_many :time_entries, dependent: :restrict_with_error
  has_many :api_tokens, dependent: :destroy
  has_many :project_memberships, dependent: :destroy
  has_many :chat_sessions, dependent: :destroy
  has_many :created_feedback_meetings, class_name: "FeedbackMeeting", foreign_key: :creator_id, dependent: :destroy
  has_many :feedback_meetings, foreign_key: :employee_id, dependent: :destroy

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

  def workspace_admin?(workspace)
    membership_for(workspace)&.workspace_admin || false
  end

  # The entry point for every authorization question about a project.
  def project_access(project)
    ProjectAccess.new(self, project)
  end

  # ---- Product access (Time & HR / Workshop) ---------------------------
  # The app is two products sharing one database. HR access is a flag on the
  # workspace membership. Workshop access is having somewhere to work: at least
  # one project where the row grants something. Keeping them on different facts
  # is what makes the product switcher honest — it appears exactly when an
  # account exists in both places, rather than when two checkboxes on one form
  # happen to agree.

  # Both the organization and the person must have it: an organization without
  # Time & HR (workspaces.hr_access, set by Flosis staff) shows it to nobody.
  def can_access_time_hr?(workspace)
    return false unless workspace&.hr_access?

    membership_for(workspace)&.time_hr_access || false
  end

  def can_access_workshop?(workspace)
    return false unless workspace
    return true if workspace_admin?(workspace)

    project_memberships.granting_anything
                       .joins(:project)
                       .where(projects: { workspace_id: workspace.id, archived: false })
                       .exists?
  end

  # Order matters: the first entry is the default landing product. The host
  # still overrides it, which is how app.flosis.com lands on the Workshop.
  def accessible_products(workspace)
    products = []
    products << :time_hr if can_access_time_hr?(workspace)
    products << :workshop if can_access_workshop?(workspace)
    products
  end

  def default_product(workspace)
    accessible_products(workspace).first
  end

  def can_access_product?(workspace, product)
    accessible_products(workspace).include?(product.to_sym)
  end
end
