# Extracts and validates the <attribution>…</attribution> block emitted by
# the bug-origin forensic-engineer AI (BugAttributionJob). The inner content
# is a single JSON object:
#   {"origin_kind": "new_functionality"|"existing_code",
#    "author_name": "…", "author_email": "…",
#    "confidence": "high"|"medium"|"low", "reasoning": "…"}
# Mirrors AlertParser/EstimateParser's conventions (BLOCK_REGEX + last-match-
# wins). Unlike AlertParser's summary truncation, origin_kind and confidence
# are hard requirements — an invalid or missing value rejects the whole
# block rather than being coerced, since a bogus attribution is worse than
# none (BugAttributionJob would just record status "failed").
#
# Usage:
#   AttributionParser.extract(assistant_text)
#   # => { origin_kind:, author_name:, author_email:, confidence:, reasoning: } or nil
class AttributionParser
  BLOCK_REGEX = %r{<attribution>\s*(.*?)\s*</attribution>}m

  # Returns the LAST valid attribution in the text (the AI's most recent
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

    origin_kind = data["origin_kind"].to_s.strip
    confidence = data["confidence"].to_s.strip
    return nil unless BugAttribution::ORIGIN_KINDS.include?(origin_kind)
    return nil unless BugAttribution::CONFIDENCES.include?(confidence)

    {
      origin_kind: origin_kind,
      author_name: data["author_name"].to_s.strip,
      author_email: data["author_email"].to_s.strip,
      confidence: confidence,
      reasoning: data["reasoning"].to_s.strip
    }
  rescue JSON::ParserError
    nil
  end
end
