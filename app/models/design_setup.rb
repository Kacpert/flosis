# One setup run of a project. Workshop Designs v2 runs it unattended from the
# setup form (Designs::SetupRunJob), in the seven steps Kacper's design lists,
# each with the minutes it usually takes; the three phases are steps 4–6. It
# is active while it runs, approved once master has it, and failed at a step,
# which "Retry" runs again. A re-import runs the same steps on a thread of its
# own, which people merge like any other.
class DesignSetup < ApplicationRecord
  PHASES = %w[design_system components designs].freeze
  STATUSES = %w[active approved failed].freeze
  STEP_MINUTES = [ 8, 2, 15, 5, 12, 15, 3 ].freeze
  # Ruling P5-R2: how long a crawl that was asked for counts as running — the
  # crawler's own 20-minute limit and five minutes more. A crawl that failed,
  # or that a deploy killed, must not hold the run's turns for ever.
  CRAWL_LIMIT = 25.minutes

  belongs_to :project
  belongs_to :started_by, class_name: "User", optional: true
  belongs_to :design_thread, optional: true

  validates :phase, inclusion: { in: PHASES }
  validates :status, inclusion: { in: STATUSES }

  scope :active, -> { where(status: "active") }
  scope :running, -> { where(status: "active").where(finished_at: nil) }

  # A run that has said nothing for longer than any of its steps may take was
  # cut off (a deploy restarts the worker): it is failed, so Retry shows.
  def self.stale_after
    [ DesignTurn.stale_after, CRAWL_LIMIT ].max + 30.minutes
  end

  def self.fail_stale!
    now = Time.current
    running.where(updated_at: ...(now - stale_after)).update_all(status: "failed", error: DesignTurn::INTERRUPTED, updated_at: now)
  end

  # The design's seven steps, named for this project.
  def steps
    project = self.project
    repos = Array(project.design_app_repos).filter_map { |repo| repo.is_a?(Hash) ? repo["repo"] : repo }.presence || [ project.github_repo ].compact
    contexts = project.design_setup_roles.map(&:name)
    ui = Workshop::DesignsModuleController::UI_SYSTEMS.fetch(project.designs_ui_system, project.designs_ui_system.to_s.humanize)
    framework = Workshop::DesignsModuleController::FRAMEWORKS.fetch(project.designs_framework, project.designs_framework.to_s.humanize)
    [ "Reading #{repos.join(', ').presence || 'the app repositories'}",
      "Signing in to staging as #{contexts.join(', ').presence || 'each context'}",
      "Capturing pages for every context",
      "Extracting design tokens from #{[ ui, project.designs_ui_version ].compact_blank.join(' ')} settings",
      "Building components in #{[ framework, project.designs_framework_version ].compact_blank.join(' ')}",
      "Generating screens across #{contexts.size} contexts",
      "Committing to #{project.design_repo} @ master" ].zip(STEP_MINUTES)
  end

  def percent
    (100 * (1 - minutes_left.to_f / STEP_MINUTES.sum)).round
  end

  def minutes_left
    STEP_MINUTES.drop(step.to_i).sum
  end

  def failed? = status == "failed"
  def done? = status == "approved"

  # The phase after this one, now the run's; nil after the last, which stays.
  def next_phase!
    following = PHASES[PHASES.index(phase) + 1]
    update!(phase: following) if following
    following
  end

  def crawling?
    crawl_requested_at.present? && crawled_at.nil? && crawl_error.blank? && crawl_requested_at > CRAWL_LIMIT.ago
  end
end
