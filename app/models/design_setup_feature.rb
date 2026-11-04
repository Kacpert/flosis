# One feature of a setup run's map (the Designs setup, feature by feature):
# an area of the app a person would name, with the contexts that have it, the
# screens it was mapped with and the brief the map wrote for it. The run
# builds the features one after another, in their position's order; each is
# to do, running (building, then checking against the app), done, or failed,
# which the run notes and goes on from.
#
# On an import's page (Designs imports) a feature can also be waiting for the
# person (the AI asked them something only they can fix), in review (its
# update would replace a thread's work on master) or set aside (not needed).
# Retrying, answering or adding one queues it: it is to do again, after the
# import is over too, and the run builds it on its own branch.
class DesignSetupFeature < ApplicationRecord
  STATUSES = %w[todo running done failed waiting review set_aside].freeze
  STAGES = %w[building checking].freeze
  # Where it came from: the map, the person (Missing feature? · Add), or a
  # resync (a feature whose code changed, or one the map did not have).
  SOURCES = %w[map added changed new].freeze
  # What a turn the CLI's answer could not be read for failed with.
  UNREADABLE = /Failed to parse Claude response/
  # The note a feature that could not finish gets, which a retry drops.
  COULD_NOT_FINISH = "Could not finish: ".freeze

  belongs_to :design_setup
  belongs_to :design_turn, optional: true

  # Production is MariaDB: the columns read as text unless typed here.
  attribute :contexts, :json, default: []
  attribute :screens, :json, default: []
  attribute :notes, :json, default: []
  # A proposal waiting for review: { "comes_in", "kept", "replaced",
  # "threads", "paths" }.
  attribute :review, :json, default: {}

  validates :name, :key, :position, presence: true
  validates :status, inclusion: { in: STATUSES }
  validates :stage, inclusion: { in: STAGES }, allow_nil: true
  validates :source, inclusion: { in: SOURCES }

  # The longest key, suffix and all.
  MAX_KEY = 60

  scope :pending, -> { where(status: %w[todo running]) }
  scope :finished, -> { where(status: %w[done failed]) }
  # A card in Needs you: waiting, in review, failed, or stopped by Claude's
  # session limit until it resets.
  scope :needs_you, -> { where(status: %w[waiting review failed]).or(where(status: "todo").where.not(resets_at: nil)) }

  # The key a feature named name gets beside the taken ones: its name as a
  # slug of at most MAX_KEY characters, "feature" when nothing of it is left,
  # then -2, -3… until it is free, cut so that the suffix always fits.
  def self.key_for(name, taken)
    base = (name.to_s.parameterize.presence || "feature").first(MAX_KEY).delete_suffix("-")
    key = base
    n = 1
    while taken.include?(key)
      suffix = "-#{n += 1}"
      key = "#{base.first(MAX_KEY - suffix.length).delete_suffix('-')}#{suffix}"
    end
    key
  end

  # What its row on the progress screen says.
  def label(up_next: false)
    case status
    when "done" then notes.empty? ? "Matches the app" : "Done · #{notes.size} #{notes.size == 1 ? 'note' : 'notes'}"
    when "running" then stage == "checking" ? "Checking against the app" : "Building"
    when "failed" then "Couldn't finish"
    else up_next ? "Up next" : "To do"
    end
  end

  # How long it took, in seconds, once finished.
  def duration
    finished_at - started_at if started_at && finished_at
  end

  # What its card is about, from what happened: :waiting, :review, :limit
  # (Claude's session limit stopped it), :unreadable (the CLI's answer could
  # not be read), :error, :paused (stopped by the limit, and resuming by
  # itself), or nil for a feature with no card.
  def problem
    case status
    when "waiting" then :waiting
    when "review" then :review
    when "failed"
      if Designs::UsageLimit.hit?(error) then :limit
      elsif UNREADABLE.match?(error.to_s) then :unreadable
      else :error
      end
    when "todo" then (:paused if resets_at)
    end
  end

  # What Retry all takes: a feature that could not finish or was not
  # started. A question waits for its answer, a proposal for its review.
  def retryable?
    %i[error unreadable limit paused].include?(problem)
  end

  # To do again, at the end of the queue. fresh: built anew from master (the
  # branch it had is let go, and the AI's question with it); otherwise it goes
  # on from its branch, with reply for the AI.
  def queue!(reply: nil, fresh: true)
    update!(status: "todo", queued_at: Time.current, reply: reply.to_s.strip.presence, error: nil, stage: nil, started_at: nil,
            finished_at: nil, resets_at: nil, attempts: 0, branch: (branch unless fresh), question: (question unless fresh),
            review: (fresh ? {} : review), notes: notes.reject { |note| note.to_s.start_with?(COULD_NOT_FINISH) })
  end

  def done? = status == "done"
  def running? = status == "running"
  def failed? = status == "failed"
end
