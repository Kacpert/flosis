# One setup run of a project (see AddDesignSetups): three phases on
# wip/setup, then approval into master.
class DesignSetup < ApplicationRecord
  PHASES = %w[design_system components designs].freeze
  STATUSES = %w[active approved].freeze
  # Ruling P5-R2: how long a crawl that was asked for counts as running — the
  # crawler's own 20-minute limit and five minutes more. A crawl that failed,
  # or that a deploy killed, must not hold the run's turns for ever.
  CRAWL_LIMIT = 25.minutes

  belongs_to :project
  belongs_to :started_by, class_name: "User", optional: true

  validates :phase, inclusion: { in: PHASES }
  validates :status, inclusion: { in: STATUSES }

  scope :active, -> { where(status: "active") }

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
