# Reads the reply Claude ends a design turn with (the protocol is in
# Designs::Prompt::BASE): one <summary> block, then any number of <context>
# blocks (a context it added) and <missing> blocks (a requirement the person
# has not decided). Text outside the blocks is not part of the result, except
# when there is no summary: then that text is the summary.
#
# A setup turn (Designs imports) may also end with one <blocked> block, its
# question for the person when something only they can fix stops the
# feature, and with <comes-in>, <kept> and <replaced> blocks, one item each:
# what an update brings in, and what of a thread's work it keeps or replaces.
module Designs::TurnOutput
  Result = Data.define(:summary, :contexts, :missing, :blocked, :comes_in, :kept, :replaced) do
    def initialize(summary:, contexts: [], missing: [], blocked: nil, comes_in: [], kept: [], replaced: [])
      super
    end
  end

  SUMMARY = %r{<summary>(.*?)</summary>}mi
  CONTEXT = %r{<context>(.*?)</context>}mi
  MISSING = %r{<missing>(.*?)</missing>}mi
  BLOCKED = %r{<blocked>(.*?)</blocked>}mi
  COMES_IN = %r{<comes-in>(.*?)</comes-in>}mi
  KEPT = %r{<kept>(.*?)</kept>}mi
  REPLACED = %r{<replaced>(.*?)</replaced>}mi
  BLOCKS = [ SUMMARY, CONTEXT, MISSING, BLOCKED, COMES_IN, KEPT, REPLACED ].freeze

  # A reply that ignores the protocol still has to say something in the chat
  # and in the commit message, so its prose is its summary, cut short. The
  # blocks are left out of it, tags and contents both: the chat shows context
  # and missing blocks on their own, and never a tag. A reply made of blocks
  # only has an empty summary.
  FALLBACK_SUMMARY_LENGTH = 300

  class << self
    def parse(text)
      text = text.to_s
      blocked = blocks(text, BLOCKED).first
      Result.new(summary: summary(text, blocked), contexts: blocks(text, CONTEXT), missing: blocks(text, MISSING), blocked: blocked,
                 comes_in: blocks(text, COMES_IN), kept: blocks(text, KEPT), replaced: blocks(text, REPLACED))
    end

    private

    # A reply that is only a question has the question for its summary.
    def summary(text, blocked)
      text[SUMMARY, 1].to_s.strip.presence || prose(text).strip[0, FALLBACK_SUMMARY_LENGTH].presence ||
        blocked.to_s[0, FALLBACK_SUMMARY_LENGTH]
    end

    # The reply without its blocks, tags and contents both.
    def prose(text)
      BLOCKS.reduce(text) { |rest, block| rest.gsub(block, "") }
    end

    # A block with nothing in it says nothing, and is dropped.
    def blocks(text, pattern)
      text.scan(pattern).map { |(body)| body.strip }.reject(&:empty?)
    end
  end
end
