class Project < ApplicationRecord
  belongs_to :workspace
  belongs_to :client, optional: true
  has_many :tasks, dependent: :destroy
  has_many :delivered_issues, dependent: :destroy
  has_many :jira_boards, dependent: :destroy
  has_many :time_entries, dependent: :nullify
  has_many :project_memberships, dependent: :destroy
  has_many :members, through: :project_memberships, source: :user
  has_many :alert_rules, dependent: :destroy
  has_many :bug_attributions, dependent: :destroy

  enum :budget_type, { no_budget: 0, money: 1, hours: 2 }

  # Per-project integration secrets are encrypted at rest (Task 2). Non-secret
  # columns (repo, jira_site, jira_email, workspace_dir, checkout status) stay
  # plain. Resolution/fallback lives in ProjectCredentials, not here.
  encrypts :github_token
  encrypts :jira_api_token

  validates :name, presence: true
  validates :color, presence: true, format: { with: /\A#[0-9A-Fa-f]{6}\z/ }

  scope :active, -> { where(archived: false) }
  scope :archived, -> { where(archived: true) }

  def jira_connected?
    external_type == "jira"
  end

  ELVIUM_LEGACY_DIR = File.expand_path("~/work/elvium").freeze
  CLIENTS_BASE_DIR = ENV.fetch("CLIENTS_BASE_DIR", File.expand_path("~/work/clients")).freeze

  # The grandfathered project that keeps using the shared ~/work/elvium checkout.
  def legacy_elvium?
    workspace_dir.present? && File.expand_path(workspace_dir) == ELVIUM_LEGACY_DIR
  end

  # Absolute path to this project's isolated folder; assigns a default the first
  # time (unless already set, e.g. legacy elvium).
  def ensure_workspace_dir!
    return workspace_dir if workspace_dir.present?
    dir = File.join(CLIENTS_BASE_DIR, workspace_id.to_s, id.to_s)
    update_column(:workspace_dir, dir)
    dir
  end

  # Where Claude should chdir for automations: the repo checkout subfolder, or
  # the legacy elvium dir itself. Falls back to the shared ~/work/elvium when no
  # per-project dir is set (a project that never configured GitHub), so the
  # chdir is always a real directory.
  def repo_checkout_path
    return ELVIUM_LEGACY_DIR if legacy_elvium? || workspace_dir.blank?
    repo = ProjectCredentials.new(self).github_repo
    name = repo.to_s.split("/").last.presence || "repo"
    File.join(workspace_dir.to_s, name)
  end

  # Tasks in a "design" sprint (sprint name contains "design") — the candidates
  # for the Idea → Brief pipeline.
  def design_sprint_tasks
    tasks.jira_synced
         .where("LOWER(sprint_name) LIKE ?", "%design%")
         .order(:name)
  end

  CURRENCIES = %w[USD EUR GBP CAD AUD JPY CHF PLN].freeze

  PROJECT_COLORS = %w[
    #3B82F6 #EF4444 #10B981 #F59E0B #8B5CF6
    #EC4899 #06B6D4 #F97316 #84CC16 #6366F1
    #14B8A6 #E11D48 #A855F7 #0EA5E9 #D946EF
    #64748B
  ].freeze

  def budget_used_seconds
    time_entries.where.not(stopped_at: nil).sum(:duration_seconds)
  end

  def budget_used_cents
    time_entries.where.not(stopped_at: nil).sum("duration_seconds * COALESCE(hourly_rate_cents, 0) / 3600")
  end

  def budget_percentage
    case budget_type
    when "hours"
      return 0 if budget_hours.nil? || budget_hours.zero?
      (budget_used_seconds / 3600.0 / budget_hours * 100).round(1)
    when "money"
      return 0 if budget_cents.nil? || budget_cents.zero?
      (budget_used_cents.to_f / budget_cents * 100).round(1)
    else
      0
    end
  end
end
