# Extracts and validates <breakdown>…</breakdown> blocks emitted by the
# estimate-and-breakdown AI. The inner content is JSON describing a complexity
# estimate and a list of mostly-independent sub-tasks.
#
# Usage:
#   BreakdownParser.extract_all(assistant_text) # => [valid_hash, ...]
#   BreakdownParser.new(json_string).parse      # => hash or nil
#
# Only well-formed breakdowns are returned. A breakdown is well-formed when:
#   * the body is a single JSON object
#   * total_points and every subtask points are Fibonacci (1,2,3,5,8,13,21)
#   * needs_breakdown is a boolean
#   * when needs_breakdown is true there is at least one subtask
#   * each subtask has a non-blank title and a points value
class BreakdownParser
  FIBONACCI = [1, 2, 3, 5, 8, 13, 21].freeze
  BLOCK_REGEX = %r{<breakdown>\s*(.*?)\s*</breakdown>}m

  def self.extract_all(text)
    return [] if text.blank?
    text.scan(BLOCK_REGEX).filter_map { |(body)| new(body).parse }
  end

  # Returns the LAST valid breakdown in the text (the AI's most recent
  # revision within a single message), or nil if none is valid.
  def self.extract_latest(text)
    extract_all(text).last
  end

  def initialize(raw)
    @raw = raw.to_s
  end

  def parse
    data = JSON.parse(@raw)
    return nil unless data.is_a?(Hash)

    normalized = normalize(data)
    valid?(normalized) ? normalized : nil
  rescue JSON::ParserError
    nil
  end

  private

  def normalize(data)
    subtasks = Array(data["subtasks"]).map do |st|
      next nil unless st.is_a?(Hash)
      {
        "title" => st["title"].to_s.strip,
        "points" => coerce_int(st["points"]),
        "description" => st["description"].to_s.strip,
        "order" => coerce_int(st["order"]),
        "depends_on" => Array(st["depends_on"]).map(&:to_s)
      }
    end.compact

    needs_breakdown = to_bool(data["needs_breakdown"])

    # total_points is the SUM of the sub-task points — an epic's total can and
    # often should exceed 21. We compute it server-side so it always matches
    # the slices on screen (the AI's own total is ignored to avoid arithmetic
    # drift). For a small, un-split task it's the single whole-task estimate.
    total_points = if subtasks.any?
      subtasks.sum { |st| st["points"] || 0 }
    else
      coerce_int(data["total_points"])
    end

    {
      "needs_breakdown" => needs_breakdown,
      "total_points" => total_points,
      "strategy" => data["strategy"].to_s.strip,
      "warning" => data["warning"].to_s.strip.presence,
      "subtasks" => subtasks
    }
  end

  def valid?(b)
    return false if b["needs_breakdown"] && b["subtasks"].empty?

    if b["subtasks"].any?
      # Only the individual slices are constrained to Fibonacci; the total is
      # their (possibly >21) sum.
      b["subtasks"].all? { |st| st["title"].present? && FIBONACCI.include?(st["points"]) }
    else
      # Un-split task: the single whole-task estimate must be a Fibonacci value.
      FIBONACCI.include?(b["total_points"])
    end
  end

  def coerce_int(value)
    return value if value.is_a?(Integer)
    return nil if value.nil?
    Integer(value.to_s.strip)
  rescue ArgumentError, TypeError
    nil
  end

  def to_bool(value)
    return value if [true, false].include?(value)
    return false if value.nil?
    %w[true 1 yes].include?(value.to_s.strip.downcase)
  end
end
