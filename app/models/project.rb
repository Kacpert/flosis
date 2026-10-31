class Project < ApplicationRecord
  include EstimationSettings

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
  # :nullify rather than :destroy — a webhook that outlives its project is a
  # stray row, but a deleted webhook is a silently broken alert.
  has_many :discord_webhooks, dependent: :nullify
  # A review that outlives its project is a stray row; deleting it would erase
  # the workspace's review history the Process page reports on.
  has_many :pr_reviews, dependent: :nullify

  enum :budget_type, { no_budget: 0, money: 1, hours: 2 }

  # Per-project integration secrets are encrypted at rest (Task 2). Non-secret
  # columns (repo, jira_site, jira_email, workspace_dir, checkout status) stay
  # plain. Resolution/fallback lives in ProjectCredentials, not here.
  encrypts :github_token
  encrypts :jira_api_token
  encrypts :figma_token
  encrypts :anthropic_api_key
  encrypts :design_repo_token

  # The CSS a new design repo is built on: Tailwind v4, or plain CSS with no
  # utility framework at all.
  DESIGN_BASE_KITS = %w[tailwind4 plain].freeze

  # The repository is pasted from the browser's address bar as often as it is
  # typed, so a GitHub address is forgiven: surrounding whitespace, a leading
  # https://github.com/ and a trailing .git or slash are dropped, and
  # "https://github.com/acme/designs.git" is "acme/designs". Anything else is
  # left as it came, for the format below to refuse.
  normalizes :design_repo, with: ->(repo) {
    repo.strip.sub(%r{\Ahttps://github\.com/}i, "").sub(%r{(?:\.git|/)+\z}i, "")
  }

  # A setup run's inputs (Workshop::DesignSetupInputsController), for staff.
  has_many :design_setup_roles, -> { order(:position, :id) }, dependent: :destroy
  has_many_attached :design_materials
  # JSON with no database default, which MySQL could not give (see
  # DesignRequest#links).
  attribute :design_figma_urls, :json, default: []

  validates :name, presence: true
  validates :design_app_url, format: { with: %r{\Ahttps?://[^\s]+\z}i, message: "must be an http(s) address" }, allow_blank: true
  validates :color, presence: true, format: { with: /\A#[0-9A-Fa-f]{6}\z/ }
  validates :design_base_kit, inclusion: { in: DESIGN_BASE_KITS }
  # owner/name, never a URL: it is handed to git and to the GitHub API as it is.
  # In the app this refusal is shown as an alert on the Designs tab, so it says
  # what to type rather than only that something is wrong.
  validates :design_repo, format: { with: %r{\A[\w.-]+/[\w.-]+\z}, message: "must look like owner/name" }, allow_blank: true
  # GitHub's own limits: an owner of 39 characters, a name of 100.
  validates :design_repo, length: { maximum: 140 }
  validate :design_repo_is_not_the_app_repo
  # A style pack is chosen by key, and only an active one can be chosen. One
  # chosen before staff switched it off stays until someone picks another:
  # turns run without it meanwhile (Designs::Library), and the rest of the
  # Designs tab still saves.
  normalizes :design_style_pack_key, with: ->(key) { key.strip.presence }
  validate :design_style_pack_is_available, if: :will_save_change_to_design_style_pack_key?

  scope :active, -> { where(archived: false) }
  scope :archived, -> { where(archived: true) }
  # The projects that appear in Flosis. A Time & HR project exists so hours
  # have somewhere to land; it only reaches the Workshop when someone says so
  # (Time & HR -> the project -> "Show this project in Flosis"). Time tracking
  # never consults this — see WorkspaceScoped#available_projects.
  scope :in_workshop, -> { where(show_in_workshop: true) }

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

  # Designs is on and its repo was set up: what the Designs screen needs.
  def designs_ready?
    designs_enabled? && design_repo_status == "ready"
  end

  # Where the project's design repo lives (its clone, worktrees and lock): the
  # project's own folder. The legacy Elvium project's workspace_dir is the app
  # checkout itself, so Elvium gets the folder any other project would have.
  def designs_dir
    return File.join(CLIENTS_BASE_DIR, workspace_id.to_s, id.to_s) if legacy_elvium?

    ensure_workspace_dir!
  end

  # The segment of every preview link that makes it unguessable. Made the first
  # time it is needed rather than at creation, so a project that never turns
  # Designs on never carries one.
  def ensure_design_preview_token!
    return design_preview_token if design_preview_token.present?
    token = SecureRandom.alphanumeric(32)
    update_column(:design_preview_token, token)
    token
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

  # What the AI jobs may read, which is narrower: the fallback above makes a
  # project with no folder of its own resolve to the shared elvium tree, and an
  # answer about somebody else's codebase presented as this project's is worse
  # than no answer. nil means "skip", not "use the default".
  def ai_codebase_path
    return repo_checkout_path if legacy_elvium?
    return nil if workspace_dir.blank?

    path = repo_checkout_path
    path if Dir.exist?(path)
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

  private

  # Designs pushes a branch per task and merges approvals into the design
  # repo's master, and the client's application repository is never changed.
  # GitHub names ignore case, and the app repo is read the way a pasted design
  # repo is, so "https://github.com/Acme/App.git" is still acme/app.
  def design_style_pack_is_available
    return if design_style_pack_key.blank?
    return if LibraryEntry.active.of_kind("style_pack").exists?(key: design_style_pack_key)

    errors.add(:design_style_pack_key, "is not an available style pack")
  end

  def design_repo_is_not_the_app_repo
    return if design_repo.blank? || github_repo.blank?
    return unless design_repo.casecmp?(self.class.normalize_value_for(:design_repo, github_repo))

    errors.add(:design_repo, "must be a different repository from the app's")
  end
end
