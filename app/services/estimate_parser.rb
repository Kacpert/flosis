# Extracts and validates the <estimate>…</estimate> block emitted by the
# AI auto-estimation engine (AutoEstimateJob). The inner content is a single
# JSON object with a COMPLEXITY/EFFORT score on a fixed 1–100 scale (anchored
# by the rubric in the prompt) plus a short rationale — unlike BreakdownParser,
# there is no sub-task splitting here.
#
# The 1–100 score is HALVED (÷2, rounded to a whole number) into the stored
# `points` value — so the persisted range is 1–50. Halving here (not in the
# prompt) keeps the AI reasoning on the richer 1–100 rubric while the stored
# metric stays on the team's chosen scale.
#
# Usage:
#   EstimateParser.extract(assistant_text) # => { score:, points:, rationale: } or nil
class EstimateParser
  BLOCK_REGEX = %r{<estimate>\s*(.*?)\s*</estimate>}m
  MIN_SCORE = 1
  MAX_SCORE = 100

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

    # Accept "score" (new 1–100 rubric) or fall back to a legacy "points" key.
    score = coerce_int(data["score"] || data["points"])
    return nil if score.nil? || score < MIN_SCORE || score > MAX_SCORE

    { score: score, points: (score / 2.0).round, rationale: data["rationale"].to_s.strip }
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
