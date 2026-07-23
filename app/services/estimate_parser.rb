# Extracts and validates the <estimate>…</estimate> block emitted by the
# AI auto-estimation engine (AutoEstimateJob). The inner content is a single
# JSON object with an open-ended COMPLEXITY estimate (any positive whole
# number — no Fibonacci scale, no upper limit) and a short rationale — unlike
# BreakdownParser, there is no sub-task splitting here.
#
# Usage:
#   EstimateParser.extract(assistant_text) # => { points:, rationale: } or nil
class EstimateParser
  BLOCK_REGEX = %r{<estimate>\s*(.*?)\s*</estimate>}m
  # The DB column is decimal(5,1) → whole numbers up to 9999 fit. This is a
  # storage safeguard, not a product cap.
  MAX_POINTS = 9999

  # Returns the LAST valid estimate in the text (the AI's most recent
  # revision within a single message), or nil if none is valid.
  def self.extract(text)
    return nil if text.blank?
    text.scan(BLOCK_REGEX).filter_map { |(body)| new(body).parse }.last
  end

  def initialize(raw)
    @raw = raw.to_s
  end

  def parse
    data = JSON.parse(@raw)
    return nil unless data.is_a?(Hash)

    points = coerce_int(data["points"])
    # Any positive whole number is valid (no Fibonacci scale, no upper limit);
    # only reject non-numbers, zero/negatives, and values too big to store.
    return nil if points.nil? || points < 1 || points > MAX_POINTS

    { points: points, rationale: data["rationale"].to_s.strip }
  rescue JSON::ParserError
    nil
  end

  private

  def coerce_int(value)
    return value if value.is_a?(Integer)
    return nil if value.nil?
    Integer(value.to_s.strip)
  rescue ArgumentError, TypeError
    nil
  end
end
