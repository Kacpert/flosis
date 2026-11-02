# A scheduled natural-language condition, checked by AlertRuleRunJob against a
# JSON snapshot of the live Jira board (see AlertRuleRunJob), that posts to a
# Discord channel only when the condition is met.
#
# `due?(now)` is the scheduling core (unit-tested exhaustively in
# test/models/alert_rule_test.rb) — AlertRulesDispatchJob enqueues a run for
# every ACTIVE rule where `due?` is true. All time math is expected to run in
# the app time zone (Warsaw, config.time_zone) — callers must pass a
# Time.current-derived value, never Time.now.
class AlertRule < ApplicationRecord
  belongs_to :workspace
  belongs_to :project
  # Optional: notifications are opt-in (notify_enabled). A rule with notifications
  # off has no webhook and simply posts nothing.
  belongs_to :discord_webhook, optional: true
  has_many :alert_runs, dependent: :destroy
  # Superseded prompt texts, newest first. The live text stays on this record;
  # a version is written only when the prompt actually changes.
  has_many :prompt_versions, -> { newest_first }, class_name: "AlertRulePromptVersion", dependent: :destroy

  FREQUENCIES = %w[daily weekdays mwf weekly hourly].freeze

  # ---- schedule builder -------------------------------------------------
  # A schedule is (mode, days, and either a time-of-day or an hour interval):
  #   daily    — every day at run_at_time
  #   days     — only on schedule_days, at run_at_time
  #   interval — every interval_hours, on schedule_days, optionally only
  #              between window_from and window_to
  # `frequency` is kept in sync as a legacy mirror (see #sync_legacy_frequency)
  # but nothing reads it for scheduling any more.
  SCHEDULE_MODES = %w[daily days interval].freeze
  DAY_NAMES = %w[Mon Tue Wed Thu Fri Sat Sun].freeze
  WEEKDAYS = %w[Mon Tue Wed Thu Fri].freeze
  WEEKENDS = %w[Sat Sun].freeze
  # Date#wday is 0=Sun..6=Sat; DAY_NAMES is Mon-first.
  WDAY_TO_NAME = { 0 => "Sun", 1 => "Mon", 2 => "Tue", 3 => "Wed", 4 => "Thu", 5 => "Fri", 6 => "Sat" }.freeze
  MIN_INTERVAL_HOURS = 1
  MAX_INTERVAL_HOURS = 24

  # Hard cap on the AI-managed memory blob (backstop; the prompt also tells the
  # AI to prune). 200KB of JSON text — far more than any sane automation needs.
  MEMORY_MAX_BYTES = 200_000

  # How many superseded prompts to keep. Enough to walk back through a few
  # rewrites; not so many that a rule edited daily grows without bound.
  MAX_PROMPT_VERSIONS = 20

  before_validation :normalize_schedule
  before_update :snapshot_previous_prompt

  validates :name, presence: true
  validates :prompt, presence: true
  validates :frequency, presence: true, inclusion: { in: FREQUENCIES }
  validates :schedule_mode, presence: true, inclusion: { in: SCHEDULE_MODES }
  validates :run_at_time, presence: true, unless: :interval_mode?
  validates :interval_hours, numericality: {
    only_integer: true, greater_than_or_equal_to: MIN_INTERVAL_HOURS, less_than_or_equal_to: MAX_INTERVAL_HOURS
  }, if: :interval_mode?
  validate :at_least_one_day
  # If notifications are on, a channel must be chosen; off = no channel needed.
  validates :discord_webhook, presence: true, if: :notify_enabled?

  scope :active, -> { where(active: true) }
  # Hand-arranged order (drag and drop in the rules list). created_at is the
  # tiebreaker so a rule whose position was never set still lands somewhere
  # sensible rather than at a random spot.
  #
  # CASE WHEN rather than NULLS LAST, and the column qualified: production is
  # MySQL while development is Postgres, and MySQL understands neither NULLS
  # LAST nor a bare `position` without ambiguity against POSITION().
  scope :ordered, lambda {
    order(Arel.sql("CASE WHEN alert_rules.position IS NULL THEN 1 ELSE 0 END"))
      .order(:position)
      .order(created_at: :desc)
  }

  before_create :assign_position

  FREQUENCY_LABELS = {
    "daily"    => "Daily",
    "weekdays" => "Weekdays",
    "mwf"      => "Mon, Wed, Fri",
    "weekly"   => "Weekly (Mon)",
    "hourly"   => "Every hour"
  }.freeze

  HOURLY_THRESHOLD = 55.minutes

  # AlertRulesDispatchJob runs every 5 minutes; without this slack an "every 4h"
  # rule would slip 5 minutes later on every fire and eventually skip a slot.
  DISPATCH_SLACK = 5.minutes

  # Weekday matcher per frequency — Date#wday: 0=Sun .. 6=Sat.
  FREQUENCY_WDAYS = {
    "daily"    => (0..6).to_a,
    "weekdays" => (1..5).to_a,
    "mwf"      => [1, 3, 5],
    "weekly"   => [1] # Monday
  }.freeze

  # The schedule each legacy frequency translates to. Used both by the backfill
  # migration and by #normalize_schedule, so a caller that still passes only
  # `frequency:` (the pre-builder API) keeps exactly the cadence it asked for.
  FREQUENCY_SCHEDULES = {
    "daily"    => { schedule_mode: "daily",    days: DAY_NAMES },
    "weekdays" => { schedule_mode: "days",     days: WEEKDAYS },
    "mwf"      => { schedule_mode: "days",     days: %w[Mon Wed Fri] },
    "weekly"   => { schedule_mode: "days",     days: %w[Mon] },
    "hourly"   => { schedule_mode: "interval", days: DAY_NAMES, interval_hours: 1, window_enabled: false }
  }.freeze

  # Assigning any of these means the caller used the schedule builder, so
  # `frequency` must not override it.
  SCHEDULE_ATTRIBUTES = %w[schedule_mode schedule_days interval_hours window_enabled window_from window_to].freeze

  # The weekdays this rule may run on, as Mon-first short names.
  def days
    schedule_days.to_s.split(",").map(&:strip).select { |d| DAY_NAMES.include?(d) }
  end

  def days=(values)
    list = Array(values).map(&:to_s).map(&:strip).select { |d| DAY_NAMES.include?(d) }
    self.schedule_days = DAY_NAMES.select { |d| list.include?(d) }.join(",")
  end

  def interval_mode? = schedule_mode == "interval"

  # Is this rule due to run, evaluated at `now` (a Time in the app zone)?
  #
  # - interval: due on an allowed weekday, inside the optional time window,
  #   when the last run was at least interval_hours ago. The 5-minute slack
  #   keeps a 5-minute dispatch cadence (AlertRulesDispatchJob /
  #   config/recurring.yml) from drifting a rule past its slot every time.
  # - daily / days: due when TODAY is an allowed weekday AND `now` is at/after
  #   today's run_at_time AND the rule hasn't already run since that time today.
  def due?(now)
    resolve_schedule
    return false unless day_allowed?(now)
    return interval_due?(now) if interval_mode?

    scheduled_at = today_scheduled_time(now)
    return false if scheduled_at.nil?
    return false if now < scheduled_at
    # A slot that had already passed when the rule was written is not a missed
    # run — it happened before the rule existed. Saving a "weekdays at 10:00"
    # rule in the afternoon used to fire it within five minutes, which for a
    # notifying rule means pinging real people the moment you hit save.
    return false if created_at.present? && scheduled_at < created_at

    last_run_at.nil? || last_run_at < scheduled_at
  end

  # "Daily · 13:00" · "Weekdays · 09:00" · "Weekdays · Every 4h · 09:00–18:00"
  # — the rules-list card's schedule line, and the live preview in the builder.
  def schedule_label
    resolve_schedule
    label = day_label

    if interval_mode?
      parts = [ label.presence, "Every #{interval_hours}h" ].compact
      parts << "#{window_from}–#{window_to}" if window_enabled?
      return parts.join(" · ")
    end

    "#{label.presence || 'Daily'} · #{run_at_time}"
  end

  # "" when every day is selected (the caller says "Daily" instead), else
  # "Weekdays" / "Weekends" / "Mon, Wed, Fri".
  def day_label
    selected = days
    return "" if selected.empty? || selected.size == DAY_NAMES.size
    return "Weekdays" if selected == WEEKDAYS
    return "Weekends" if selected == WEEKENDS
    selected.join(", ")
  end

  # Most recent AlertRun, if any — drives the "last" status chip.
  def last_run
    alert_runs.newest_first.first
  end

  # :not_run | :error | :fired | :quiet — chip state for the rules list card.
  def last_run_status
    run = last_run
    return :not_run if run.nil?
    return :error if run.status == "error"
    run.fired? ? :fired : :quiet
  end

  # "Sent · {summary}" / "No condition met" / "Not run yet" / "Run failed" —
  # the chip label itself.
  def last_run_chip_label
    run = last_run
    case last_run_status
    when :not_run then "Not run yet"
    when :error   then run.summary.presence || "Run failed"
    when :fired   then "Sent · #{run.summary}"
    else "No condition met"
    end
  end

  # ---- AI-managed memory ------------------------------------------------
  # The AI reads this at the start of each run (so it doesn't redo work) and
  # returns a full replacement blob at the end. Stored as a JSON string in the
  # :text column for MySQL/Postgres portability; the reader returns the raw
  # string (the AI works with text — we don't force a shape on it).

  # The raw memory text the AI last stored (or "" when never set).
  def memory_text
    memory.to_s
  end

  # Problems the AI last reported (missing permission, bad key, …), or "".
  def ai_issues_text
    ai_issues.to_s
  end

  # Persist a new memory blob returned by the AI. Enforces the hard size cap:
  # an over-limit blob is REJECTED (not saved) and reported, so one runaway
  # automation can't bloat the table. Returns true on save, false if rejected.
  def store_memory(text)
    store_blob(:memory, text)
  end

  # Persist the AI's reported issues (same size-cap contract as memory).
  def store_ai_issues(text)
    store_blob(:ai_issues, text)
  end

  # Memory is viewable/clearable but never editable — an operator can wipe it to
  # force the automation to rebuild its state from scratch.
  def clear_memory!
    update_column(:memory, nil)
  end

  def clear_ai_issues!
    update_column(:ai_issues, nil)
  end

  private

  # Keep the wording this rule is being edited away from. Written before the
  # change lands, so prompt_was is the text that is about to be lost.
  def snapshot_previous_prompt
    return unless prompt_changed?

    previous = prompt_was
    return if previous.blank?

    prompt_versions.create!(prompt: previous, created_at: Time.current)
    prune_prompt_versions
  end

  def prune_prompt_versions
    surplus = prompt_versions.newest_first.offset(MAX_PROMPT_VERSIONS).pluck(:id)
    AlertRulePromptVersion.where(id: surplus).delete_all if surplus.any?
  end

  # New rules go to the end of their project's list, not the top: the order is
  # something the operator arranges, so nothing should reshuffle itself.
  def assign_position
    return if position.present?

    self.position = (self.class.where(project_id: project_id).maximum(:position) || 0) + 1
  end

  # Persist an AI-managed text blob to `column`, enforcing the hard size cap so a
  # runaway automation can't bloat the table. Returns true/false (saved?).
  def store_blob(column, text)
    text = text.to_s
    if text.bytesize > MEMORY_MAX_BYTES
      Rails.logger.warn("[AlertRule ##{id}] #{column} blob #{text.bytesize}B exceeds #{MEMORY_MAX_BYTES}B cap — not saved")
      return false
    end
    update_column(column, text.presence)
    true
  end

  def hourly_due?(now)
    last_run_at.nil? || last_run_at <= now - HOURLY_THRESHOLD
  end

  # Daily mode ignores the day list entirely (it means "every day"); days and
  # interval modes honour it.
  def day_allowed?(now)
    return true if schedule_mode == "daily"
    days.include?(WDAY_TO_NAME[now.wday])
  end

  # Same rule for interval mode: a brand-new rule waits out one interval rather
  # than firing on the first dispatch after it was saved.
  def interval_due?(now)
    return false if window_enabled? && !inside_window?(now)

    since = last_run_at || created_at
    return true if since.nil?

    since <= now - (interval_hours.hours - DISPATCH_SLACK)
  end

  # Inclusive on both ends. A window whose end is at/before its start (e.g.
  # 22:00–06:00) wraps past midnight.
  def inside_window?(now)
    from = minutes_of_day(window_from)
    to = minutes_of_day(window_to)
    return true if from.nil? || to.nil?

    current = now.hour * 60 + now.min
    from <= to ? current.between?(from, to) : (current >= from || current <= to)
  end

  def minutes_of_day(value)
    hour, minute = value.to_s.split(":").map(&:to_i)
    return nil if hour.nil? || minute.nil?
    hour * 60 + minute
  end

  def today_scheduled_time(now)
    return nil if run_at_time.blank?
    hour, minute = run_at_time.split(":").map(&:to_i)
    now.change(hour: hour, min: minute, sec: 0, usec: 0)
  rescue ArgumentError
    nil
  end

  # Fill in sane defaults and keep the legacy `frequency` column consistent so
  # nothing that still reads it (or its NOT NULL + inclusion validation) breaks.
  # An AlertRule built with only `frequency:` (the pre-builder API — still used
  # by tests and any older caller) hasn't been through normalize_schedule yet,
  # so its schedule columns sit at their defaults. Because `frequency` is kept
  # in sync on every save, a saved rule always agrees with its own schedule;
  # a disagreement therefore means "these columns were never set" — resolve
  # them from the frequency in memory so reads behave identically either way.
  def resolve_schedule
    return if @schedule_resolved
    @schedule_resolved = true
    return unless FREQUENCY_SCHEDULES.key?(frequency)
    apply_frequency_schedule if legacy_frequency != frequency
  end

  def normalize_schedule
    apply_frequency_schedule if derive_schedule_from_frequency?
    @schedule_resolved = true
    self.schedule_mode = "daily" unless SCHEDULE_MODES.include?(schedule_mode)
    self.days = DAY_NAMES if days.empty? && schedule_mode != "days"
    self.interval_hours = interval_hours.to_i.clamp(MIN_INTERVAL_HOURS, MAX_INTERVAL_HOURS)
    self.run_at_time = "09:00" if run_at_time.blank? && !interval_mode?
    self.window_from = "09:00" if window_from.blank?
    self.window_to = "18:00" if window_to.blank?
    self.frequency = legacy_frequency
  end

  # Only when the caller set `frequency` and touched none of the schedule
  # fields — i.e. the old API. The builder always assigns schedule fields, so
  # it never triggers this.
  def derive_schedule_from_frequency?
    frequency_changed? && FREQUENCY_SCHEDULES.key?(frequency) && (changed & SCHEDULE_ATTRIBUTES).empty?
  end

  def apply_frequency_schedule
    spec = FREQUENCY_SCHEDULES.fetch(frequency)
    self.schedule_mode = spec[:schedule_mode]
    self.days = spec[:days]
    self.interval_hours = spec[:interval_hours] if spec.key?(:interval_hours)
    self.window_enabled = spec[:window_enabled] if spec.key?(:window_enabled)
  end

  def legacy_frequency
    return "hourly" if interval_mode?

    case days
    when WEEKDAYS then "weekdays"
    when %w[Mon Wed Fri] then "mwf"
    when %w[Mon] then "weekly"
    else "daily"
    end
  end

  def at_least_one_day
    return unless schedule_mode == "days" || interval_mode?
    errors.add(:schedule_days, "must include at least one day") if days.empty?
  end
end
