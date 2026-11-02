# Shared coercion for the trend-card controls used by BOTH Reporting and Bug
# Reporting, so the two cards behave identically (same granularities, same
# ranges, same chart types) — see app/views/workshop/{reports,bugs}/_trend_card.
#
# The user picks a WINDOW in months (2m / 3m / 6m / 1y / 2y) and, separately, a
# BUCKET SIZE (weeks / 2 weeks / months / sprints). `bucket_count` converts the
# two into the number of buckets WorkshopReport#trend should build, matching
# ClearBacklog.html's ptsForRange().
module Workshop::TrendControls
  extend ActiveSupport::Concern

  GRANULARITIES = %w[weeks fortnights months sprints].freeze
  DEFAULT_GRAN = "weeks".freeze

  # Window in MONTHS, regardless of the bucket size.
  RANGES = [ 2, 3, 6, 12, 24 ].freeze
  DEFAULT_RANGE = 2

  CHART_TYPES = %w[line bar].freeze
  DEFAULT_CHART = "line".freeze

  # Average weeks/fortnights/sprints per month — 4.345 weeks per month is the
  # 365.25/12/7 average; sprints are assumed two-weekly.
  BUCKETS_PER_MONTH = {
    "weeks" => 4.345,
    "fortnights" => 2.17,
    "sprints" => 2.0,
    "months" => 1.0
  }.freeze

  def coerce_gran(raw)
    GRANULARITIES.include?(raw.to_s) ? raw.to_s : DEFAULT_GRAN
  end

  def coerce_range(raw)
    value = raw.to_i
    RANGES.include?(value) ? value : DEFAULT_RANGE
  end

  def coerce_chart(raw)
    CHART_TYPES.include?(raw.to_s) ? raw.to_s : DEFAULT_CHART
  end

  # How many buckets of `gran` fit in a `months`-month window (min 2, so a
  # 2m/sprints view still draws a line rather than a single dot).
  def bucket_count(gran, months)
    [ (months * BUCKETS_PER_MONTH.fetch(gran, 1.0)).round, 2 ].max
  end
end
