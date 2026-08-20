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

  # A "workspace client": full Workshop access WITH pricing, but no Time & HR.
  # Distinct from the Jira-Tasks-only `client` role.
  def workspace_client_role?(workspace)
    role_in(workspace) == "workspace_client"
  end

  # Clients get Jira-tasks-only access alongside employees/admins/owners.
  def client_or_employee?(workspace)
    client_role?(workspace) || at_least_employee?(workspace)
  end

  # Pricing (rates/revenue/costs) is visible to admins/owners and to
  # workspace_clients — the latter get a full, priced view of the Workshop.
  def can_see_money?(workspace)
    admin_or_owner?(workspace) || workspace_client_role?(workspace)
  end

  # ---- Product access (Time & HR / Workshop) ---------------------------
  # The app is split into two products that share one DB. Access is per-user
  # per-workspace, stored on the membership. Clients are a special case: they
  # are Jira-Tasks-only, which lives in the Workshop product.

  # The Jira-Tasks-only `client` role is never a Time & HR user. A
  # `workspace_client` is Workshop-first, but an admin can additionally switch
  # Time & HR on for them — some clients want to log their own hours — in which
  # case the per-membership flag governs, exactly as it does for an employee.
  def can_access_time_hr?(workspace)
    return false if client_role?(workspace)
    membership_for(workspace)&.time_hr_access || false
  end

  # "May use Time & HR the way an employee does" — log time, run a timer, tag
  # entries, file holidays. Deliberately separate from at_least_employee?, which
  # is a pure ROLE question used outside this product too; widening that would
  # hand workspace_clients employee powers in places this feature never meant to
  # touch.
  def time_hr_member?(workspace)
    return true if at_least_employee?(workspace)

    workspace_client_role?(workspace) && can_access_time_hr?(workspace)
  end

  # Access to the Workshop PRODUCT (Jira Tasks + conceptual tooling). This is the
  # per-user product gate and is independent of the workspace `workshop_enabled`
  # feature flag — that flag only gates the Workshop briefing tab within the
  # product. Clients are Jira-Tasks-only, which lives in this product.
  def can_access_workshop?(workspace)
    return false unless workspace
    return true if client_role?(workspace)
    return true if workspace_client_role?(workspace) # full Workshop access
    membership_for(workspace)&.workshop_access || false
  end

  # Ordered list of products the user can access in this workspace.
  # Order matters: the first entry is the default landing product. A
  # workspace_client holds an account for the Workshop, so that stays their
  # default even once Time & HR is switched on for them.
  def accessible_products(workspace)
    products = []
    products << :time_hr if can_access_time_hr?(workspace)
    products << :workshop if can_access_workshop?(workspace)
    products.reverse! if workspace_client_role?(workspace)
    products
  end

  def default_product(workspace)
    accessible_products(workspace).first
  end

  def can_access_product?(workspace, product)
    accessible_products(workspace).include?(product.to_sym)
  end
end
