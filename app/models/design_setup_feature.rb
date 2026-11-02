# One feature of a setup run's map (the Designs setup, feature by feature):
# an area of the app a person would name, with the contexts that have it, the
# screens it was mapped with and the brief the map wrote for it. The run
# builds the features one after another, in their position's order; each is
# to do, running (building, then checking against the app), done, or failed,
# which the run notes and goes on from.
class DesignSetupFeature < ApplicationRecord
  STATUSES = %w[todo running done failed].freeze
  STAGES = %w[building checking].freeze

  belongs_to :design_setup
  belongs_to :design_turn, optional: true

  # Production is MariaDB: the columns read as text unless typed here.
  attribute :contexts, :json, default: []
  attribute :screens, :json, default: []
  attribute :notes, :json, default: []

  validates :name, :key, :position, presence: true
  validates :status, inclusion: { in: STATUSES }
  validates :stage, inclusion: { in: STAGES }, allow_nil: true

  scope :pending, -> { where(status: %w[todo running]) }
  scope :finished, -> { where(status: %w[done failed]) }

  # The key a feature named name gets beside the taken ones: its name as a
  # slug, "feature" when nothing of it is left, then -2, -3… until it is free.
  def self.key_for(name, taken)
    base = name.to_s.parameterize.presence || "feature"
    key = base
    n = 1
    key = "#{base}-#{n += 1}" while taken.include?(key)
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

  def done? = status == "done"
  def running? = status == "running"
  def failed? = status == "failed"
end
