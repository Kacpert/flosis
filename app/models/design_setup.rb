# One setup run of a project: the Designs setup, feature by feature. Started
# from the setup form, it runs unattended (Designs::SetupRunJob) in the six
# steps the progress screen lists: it reads the app's repositories, signs in to
# the test environment as each context, maps the app's features, builds the
# design system, builds and checks the features one after another, and lands
# it all on master. Each step but the features has the minutes it usually
# takes; the features take FEATURE_MINUTES each.
#
# A job works on the run one unit at a time (a step, or one feature) and
# claims it until a deadline: a run a deploy cut off is found stalled once its
# deadline passes and picked up again (Designs::ResumeSetupsJob). A run is
# active while it goes, approved once master has it, and failed when it cannot
# go on at all; what only makes the design differ from the app is a note.
class DesignSetup < ApplicationRecord
  # The phase prompt the run's turns get (Designs::SetupPrompts).
  PHASES = %w[map design_system feature].freeze
  STATUSES = %w[active approved failed].freeze
  STEPS = %i[read_repos sign_in map_features design_system features commit].freeze
  STEP_MINUTES = [ 10, 2, 20, 30, nil, 3 ].freeze
  FEATURES_STEP = STEPS.index(:features)
  FEATURE_MINUTES = 30
  # What the time left counts on before the map says how many there are.
  GUESSED_FEATURES = 15

  belongs_to :project
  belongs_to :started_by, class_name: "User", optional: true
  belongs_to :design_thread, optional: true
  has_many :features, -> { order(:position) }, class_name: "DesignSetupFeature", dependent: :destroy

  # Production is MariaDB: the columns read as text unless typed here.
  attribute :notes, :json, default: []
  attribute :step_seconds, :json, default: []

  validates :phase, inclusion: { in: PHASES }
  validates :status, inclusion: { in: STATUSES }

  scope :active, -> { where(status: "active") }
  scope :running, -> { where(status: "active").where(finished_at: nil) }
  # Running, with a unit whose deadline has passed: its job is gone.
  scope :stalled, -> { running.where.not(unit_deadline_at: nil).where(unit_deadline_at: ...Time.current) }

  # "About 6 h left", "About 40 min left".
  def self.time_left(minutes)
    minutes < 60 ? "About #{minutes} min left" : "About #{(minutes / 60.0).round} h left"
  end

  # The six steps, named for this project, each with the minutes it is
  # expected to take from now: [[label, minutes]].
  def steps
    labels = [
      "Reading #{repo_names.join(', ').presence || 'the app repositories'}",
      "Signing in as #{project.design_setup_roles.map(&:name).join(', ').presence || 'each context'}",
      features.any? ? "Mapping features: #{features.size} found" : "Mapping features",
      "Design system: tokens, fonts and icons from #{ui_system}",
      features.any? ? "Building features one by one: #{features.finished.size} of #{features.size} done" : "Building features one by one",
      "Committing to #{project.design_repo} @ master"
    ]
    labels.zip(STEP_MINUTES.map { |minutes| minutes || features_left * FEATURE_MINUTES })
  end

  def minutes_left
    steps.drop(step.to_i).sum(&:last)
  end

  def percent
    total = STEP_MINUTES.compact.sum + (features.any? ? features.size : GUESSED_FEATURES) * FEATURE_MINUTES
    (100 * (1 - minutes_left.to_f / total)).round.clamp(0, 100)
  end

  def time_left = self.class.time_left(minutes_left)

  # The step under way starts its clock once; finishing it keeps the seconds it
  # took and moves the run on.
  def start_step!
    update!(step_started_at: Time.current) unless step_started_at
  end

  def finish_step!
    seconds = step_seconds.dup
    seconds[step] = step_started_at ? (Time.current - step_started_at).round : 0
    update!(step: step + 1, step_started_at: nil, step_seconds: seconds)
  end

  # The minutes a finished step took (at least one), nil for one not finished.
  def minutes_taken(index)
    seconds = step_seconds[index]
    [ (seconds / 60.0).round, 1 ].max if seconds
  end

  # Where the run keeps what is its alone: the app's repositories, the
  # contexts' signed-in browser states, the map and the progress of a feature.
  def run_dir
    Pathname(project.designs_dir).join("design-runs", id.to_s)
  end

  # Takes the run's unit for job_id until limit from now. Another job's live
  # claim wins; the same job, delivered again after a restart, takes its unit
  # over; a claim whose deadline passed is free.
  def claim_unit!(job_id, limit:)
    with_lock do
      if unit_job_id.present? && unit_job_id != job_id && unit_deadline_at&.future?
        false
      else
        update!(unit_job_id: job_id, unit_deadline_at: limit.from_now)
        true
      end
    end
  end

  def release_unit!
    update!(unit_job_id: nil, unit_deadline_at: nil)
  end

  # The map's features, after those the run has: rows of "name", "contexts",
  # "screens", "brief" and "notes", in the map's order.
  def add_features!(rows)
    transaction do
      taken = features.pluck(:key)
      position = features.maximum(:position).to_i
      rows.each do |row|
        name = row["name"].to_s.strip.presence || "Feature"
        key = DesignSetupFeature.key_for(name, taken).first(60)
        taken << key
        features.create!(position: position += 1, key: key, name: name.truncate(120),
                         contexts: Array(row["contexts"]).map(&:to_s), screens: Array(row["screens"]).map(&:to_s),
                         brief: row["brief"].to_s, notes: Array(row["notes"]).map(&:to_s))
      end
    end
    features.reset
  end

  # A note of the run's own (a context that could not sign in, a repository
  # that could not be read), kept once.
  def note!(label, text)
    entry = { "label" => label, "text" => text.to_s.truncate(500) }
    update!(notes: notes + [ entry ]) unless notes.include?(entry)
  end

  def failed? = status == "failed"
  def done? = status == "approved"

  private

  # "acme/app @ production" for a repository named with its branch.
  def repo_names
    rows = Array(project.design_app_repos).filter_map { |row| row.is_a?(Hash) ? row["repo"] : row }
    rows = [ project.github_repo ].compact_blank if rows.empty?
    rows.map { |name| name.to_s.sub("@", " @ ") }
  end

  def ui_system
    ui = Workshop::DesignsModuleController::UI_SYSTEMS.fetch(project.designs_ui_system, project.designs_ui_system.to_s.humanize)
    [ ui, project.designs_ui_version ].compact_blank.join(" ")
  end

  def features_left
    features.any? ? features.pending.size : GUESSED_FEATURES
  end
end
