# One Claude CLI process: who it was for, what it used and what it cost
# (SCRUM-70). ClaudeCliService writes it through AiRun::Recorder: a row is
# made "running" as the CLI starts and finished when it ends, so a run that
# fails, times out or is stopped still leaves what it used.
#
# Money is in US dollars. cost_usd is what the CLI reported (nil = unknown,
# never counted as 0). price_usd is that cost plus the margin of the day the
# run happened, written once and never recomputed; an own-key run (the
# client's own Anthropic key) has no margin and is priced at its cost.
class AiRun < ApplicationRecord
  # Consumption's areas, in its order and its words.
  AREAS = {
    "task_conversations" => "Task conversations",
    "designs" => "Designs and imports",
    "pr_reviews" => "PR reviews",
    "estimates" => "AI estimates",
    "agents" => "Agents and alerts",
    "bug_analysis" => "Bug analysis",
    "feature_scan" => "Project feature scan",
    "ticket_chat" => "Chat with AI on a ticket"
  }.freeze

  STATUSES = %w[running succeeded failed stopped timed_out].freeze

  # A row still "running" this long after it started belongs to a process its
  # job no longer watches (a deploy restarted SolidQueue): AiRuns::SweepJob
  # fails it. Longer than the longest Designs setup turn (2 h).
  STALE_AFTER = 3.hours

  belongs_to :workspace
  belongs_to :project, optional: true
  belongs_to :started_by, class_name: "User", optional: true
  belongs_to :unknown_reviewed_by, class_name: "User", optional: true
  belongs_to :item, polymorphic: true, optional: true

  # MariaDB keeps a json column as text: cast it, as every json column here is.
  attribute :model_usage, :json

  validates :area, inclusion: { in: AREAS.keys }
  validates :status, inclusion: { in: STATUSES }
  validates :ran_at, presence: true

  scope :finished, -> { where.not(status: "running") }
  scope :billable, -> { finished.where(own_key: false) }
  scope :own_keyed, -> { finished.where(own_key: true) }
  scope :in_area, ->(area) { where(area: area) }
  scope :in_month, ->(date) { where(ran_at: date.in_time_zone.all_month) }
  scope :unknown_cost, -> { finished.where(cost_usd: nil) }
  scope :unreviewed_unknown, -> { unknown_cost.where(unknown_reviewed_at: nil) }

  DEFAULT_MARGIN = BigDecimal("30")

  # The margin of an organization without a plan: the "no plan" screens still
  # show a price. FLOSIS_DEFAULT_MARGIN_PERCENT may say "30" or "30%"; a value
  # that is no number falls back to 30 rather than breaking every run's price.
  def self.default_margin_percent
    raw = ENV["FLOSIS_DEFAULT_MARGIN_PERCENT"].to_s.strip.delete_suffix("%").strip
    return DEFAULT_MARGIN if raw.empty?

    BigDecimal(raw)
  rescue ArgumentError
    Rails.logger.warn("[AiRun] FLOSIS_DEFAULT_MARGIN_PERCENT=#{ENV['FLOSIS_DEFAULT_MARGIN_PERCENT'].inspect} is no number; using #{DEFAULT_MARGIN.to_i}%")
    DEFAULT_MARGIN
  end

  def item_deleted?
    item_type.present? && item.nil?
  end

  def cache_tokens
    cache_read_tokens.to_i + cache_write_tokens.to_i
  end
end
