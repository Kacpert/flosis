# Extracts and validates the <estimate>…</estimate> block emitted by the
# AI auto-estimation engine (AutoEstimateJob). The inner content is a single
# JSON object with a Fibonacci story-point estimate and a short rationale —
# unlike BreakdownParser, there is no sub-task splitting here.
#
# Usage:
#   EstimateParser.extract(assistant_text) # => { points:, rationale: } or nil
class EstimateParser
  BLOCK_REGEX = %r{<estimate>\s*(.*?)\s*</estimate>}m

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
    return nil unless BreakdownParser::FIBONACCI.include?(points)

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
