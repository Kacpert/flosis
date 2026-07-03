# Extracts and validates the <alert>…</alert> block emitted by the delivery-
# watchdog AI (AlertRuleRunJob). The inner content is a single JSON object:
#   {"fired": bool, "summary": "…", "detail": "…"}
# Mirrors EstimateParser's conventions (BLOCK_REGEX + last-match-wins), except
# the payload shape is alert-specific and `summary` is truncated to 90 chars
# rather than rejected outright, so a slightly-too-long AI summary still
# produces a usable alert instead of being silently dropped.
#
# Usage:
#   AlertParser.extract(assistant_text) # => { fired:, summary:, detail: } or nil
class AlertParser
  BLOCK_REGEX = %r{<alert>\s*(.*?)\s*</alert>}m
  SUMMARY_MAX_LENGTH = 90

  # Returns the LAST valid alert in the text (the AI's most recent revision
  # within a single message), or nil if none is valid.
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
    return nil unless data.key?("fired")

    {
      fired: !!data["fired"],
      summary: data["summary"].to_s.strip.truncate(SUMMARY_MAX_LENGTH),
      detail: data["detail"].to_s.strip
    }
  rescue JSON::ParserError
    nil
  end
end
