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

  FREQUENCIES = %w[daily weekdays mwf weekly hourly].freeze

  # Hard cap on the AI-managed memory blob (backstop; the prompt also tells the
  # AI to prune). 200KB of JSON text — far more than any sane automation needs.
  MEMORY_MAX_BYTES = 200_000

  validates :name, presence: true
  validates :prompt, presence: true
  validates :frequency, presence: true, inclusion: { in: FREQUENCIES }
  validates :run_at_time, presence: true, unless: -> { frequency == "hourly" }
  # If notifications are on, a channel must be chosen; off = no channel needed.
  validates :discord_webhook, presence: true, if: :notify_enabled?

  scope :active, -> { where(active: true) }

  FREQUENCY_LABELS = {
    "daily"    => "Daily",
    "weekdays" => "Weekdays",
    "mwf"      => "Mon, Wed, Fri",
    "weekly"   => "Weekly (Mon)",
    "hourly"   => "Every hour"
  }.freeze

  HOURLY_THRESHOLD = 55.minutes

  # Weekday matcher per frequency — Date#wday: 0=Sun .. 6=Sat.
  FREQUENCY_WDAYS = {
    "daily"    => (0..6).to_a,
    "weekdays" => (1..5).to_a,
    "mwf"      => [1, 3, 5],
    "weekly"   => [1] # Monday
  }.freeze

  # Is this rule due to run, evaluated at `now` (a Time in the app zone)?
  #
  # - hourly: due when never run, or the last run was >= 55 minutes ago (a bit
  #   under an hour, so a 5-minute dispatch cadence — see
  #   AlertRulesDispatchJob / config/recurring.yml — can't drift an hourly rule
  #   past its hour).
  # - everything else: due when TODAY matches the frequency's allowed weekdays
  #   AND `now` is at/after today's scheduled run_at_time AND the rule hasn't
  #   already run since that scheduled time today.
  def due?(now)
    return hourly_due?(now) if frequency == "hourly"

    return false unless FREQUENCY_WDAYS.fetch(frequency, []).include?(now.wday)

    scheduled_at = today_scheduled_time(now)
    return false if scheduled_at.nil?
    return false if now < scheduled_at

    last_run_at.nil? || last_run_at < scheduled_at
  end

  # "Daily · 13:00" / "Every hour" — the rules-list card's schedule line.
  def schedule_label
    label = FREQUENCY_LABELS.fetch(frequency, frequency)
    return label if frequency == "hourly" || run_at_time.blank?
    "#{label} · #{run_at_time}"
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

  def today_scheduled_time(now)
    return nil if run_at_time.blank?
    hour, minute = run_at_time.split(":").map(&:to_i)
    now.change(hour: hour, min: minute, sec: 0, usec: 0)
  rescue ArgumentError
    nil
  end
end
