# One run of Claude for one message of a Designs chat. A message creates a
# turn, Designs::TurnJob runs it, and the screen polls for how it stands.
#
# queued -> running -> succeeded or failed. A failed turn can be retried: it
# goes back to queued and is started again.
class DesignTurn < ApplicationRecord
  belongs_to :chat_session
  # The user's message this turn answers.
  belongs_to :chat_message

  STATUSES = %w[queued running succeeded failed].freeze
  # "design" answers a person's message. "resolve_conflicts" is the turn that
  # "Update from master" starts when master changed the same files. "setup" is
  # a setup run's (the map, the design system or one feature): it runs on a
  # setup turn's bounds. "components" makes components from a thread's
  # screens before it is merged (Designs::Threads.merge_or_prepare!).
  KINDS = %w[design resolve_conflicts setup components].freeze
  # Not finished yet: while a chat has one, the screen keeps polling and the
  # work cannot be approved.
  ACTIVE = %w[queued running].freeze

  # What a turn that was cut off is failed with (see .fail_stale!).
  INTERRUPTED = "Interrupted before it finished — retry it.".freeze

  # The most characters of an error that are kept. MySQL refuses a TEXT past
  # 65,535 bytes, which is 16,383 characters at four bytes each; 10,000 is well
  # inside that and far more than anyone reads in a chat.
  ERROR_LIMIT = 10_000

  # The library versions the turn's prompt was made of (Designs::Library),
  # kept here and never in the design repo: [] until it runs Claude. Typed
  # as JSON, with its default here, for MySQL (see DesignRequest#links).
  attribute :library_version_ids, :json, default: []
  # What the turn did, step by step, as Designs::TurnActivity keeps it for the
  # chat: [] until it runs Claude. JSON, with its default here, as above.
  attribute :activity, :json, default: []

  validates :status, inclusion: { in: STATUSES }
  validates :kind, inclusion: { in: KINDS }

  scope :active, -> { where(status: ACTIVE) }

  STATUSES.each do |s|
    define_method("#{s}?") { status == s }
  end

  def resolve_conflicts?
    kind == "resolve_conflicts"
  end

  def setup?
    kind == "setup"
  end

  # What a resolve_conflicts turn asks for, naming the files master changed
  # too.
  def self.resolve_request(paths)
    "Resolve the merge conflict markers in: #{paths.join(", ")}. Keep this task's intent and master's newer changes."
  end

  # A turn that starts again (a retry, or a job delivered a second time after
  # a deploy killed the first) begins with a clean slate: a running turn has no
  # finish time and no error from its last attempt.
  def start!
    update!(status: "running", started_at: Time.current, finished_at: nil, error: nil)
  end

  # commit_sha is nil when Claude's answer changed no file.
  def succeed!(commit_sha:)
    update!(status: "succeeded", commit_sha: commit_sha, finished_at: Time.current)
  end

  # The job records every error here and never re-raises one, so this must not
  # raise on a message that is too long for the column: it is cut to ERROR_LIMIT.
  def fail!(message)
    update!(status: "failed", error: message.to_s.truncate(ERROR_LIMIT), finished_at: Time.current)
  end

  # Kacper's bounds for a thread's turn (2026-11-10): a task designed from
  # scratch reads the repo and the app and writes several screens.
  DEFAULT_TIMEOUT_SECONDS = 2_400
  DEFAULT_BUDGET_USD = 40
  # A setup turn builds a whole feature, browser and all. Its bounds stop a
  # turn that runs away; they are not there to save money.
  DEFAULT_SETUP_TIMEOUT_SECONDS = 7_200
  DEFAULT_SETUP_BUDGET_USD = 60

  # How long the CLI may run one turn, in seconds: DESIGNS_TURN_TIMEOUT_SECONDS
  # when it is a positive whole number, else forty minutes. stale_after
  # counts from it too, so the two cannot drift apart.
  def self.turn_timeout
    seconds = Integer(ENV["DESIGNS_TURN_TIMEOUT_SECONDS"].to_s, 10, exception: false)
    seconds&.positive? ? seconds : DEFAULT_TIMEOUT_SECONDS
  end

  # What one turn may cost, in dollars (the CLI's --max-budget-usd):
  # DESIGNS_TURN_BUDGET_USD when it is a positive number, else forty. A value
  # that is not one gets the default, never no cap at all.
  def self.turn_budget_usd
    budget = Float(ENV["DESIGNS_TURN_BUDGET_USD"].to_s, exception: false)
    budget&.finite? && budget.positive? ? budget : DEFAULT_BUDGET_USD
  end

  # A setup turn's: DESIGNS_SETUP_TIMEOUT_SECONDS and DESIGNS_SETUP_BUDGET_USD,
  # read as the two above.
  def self.setup_timeout
    seconds = Integer(ENV["DESIGNS_SETUP_TIMEOUT_SECONDS"].to_s, 10, exception: false)
    seconds&.positive? ? seconds : DEFAULT_SETUP_TIMEOUT_SECONDS
  end

  def self.setup_budget_usd
    budget = Float(ENV["DESIGNS_SETUP_BUDGET_USD"].to_s, exception: false)
    budget&.finite? && budget.positive? ? budget : DEFAULT_SETUP_BUDGET_USD
  end

  # How long a turn may stay running before it counts as cut off: the CLI's
  # timeout (turn_timeout), plus five minutes for what Flosis does after Claude
  # answers — committing, pushing and publishing. A deploy restarts the queue
  # worker and kills a turn it was running, and nothing else would ever finish
  # or fail that turn: its row would say "running" for good, and the screen
  # would wait on it.
  def self.stale_after
    turn_timeout.seconds + 5.minutes
  end

  def self.setup_stale_after
    setup_timeout.seconds + 5.minutes
  end

  # Fails every running turn older than stale_after and returns how many. One
  # UPDATE, not a load and a save per turn: the screen calls this on every
  # poll, and a job that took a turn over in the meantime (start! sets a fresh
  # started_at) is no longer matched by the time the UPDATE runs.
  def self.fail_stale!
    now = Time.current
    failed = { status: "failed", error: INTERRUPTED, finished_at: now, updated_at: now }
    where(status: "running", started_at: ...(now - stale_after)).where.not(kind: "setup").update_all(failed) +
      where(status: "running", kind: "setup", started_at: ...(now - setup_stale_after)).update_all(failed)
  end

  # Running for longer than stale_after (setup_stale_after, for a setup turn).
  # Only a running turn can be: a queued
  # one has not started, and a finished one was not cut off.
  def stale?
    running? && started_at.present? && started_at < (setup? ? self.class.setup_stale_after : self.class.stale_after).ago
  end
end
