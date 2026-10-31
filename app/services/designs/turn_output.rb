# Reads the reply Claude ends a design turn with (the protocol is in
# Designs::Prompt::BASE): one <summary> block, then any number of <context>
# blocks (a context it added) and <missing> blocks (a requirement the person
# has not decided). Text outside the blocks is not part of the result, except
# when there is no summary: then that text is the summary.
module Designs::TurnOutput
  Result = Data.define(:summary, :contexts, :missing)

  SUMMARY = %r{<summary>(.*?)</summary>}mi
  CONTEXT = %r{<context>(.*?)</context>}mi
  MISSING = %r{<missing>(.*?)</missing>}mi

  # A reply that ignores the protocol still has to say something in the chat
  # and in the commit message, so its prose is its summary, cut short. The
  # blocks are left out of it, tags and contents both: the chat shows context
  # and missing blocks on their own, and never a tag. A reply made of blocks
  # only has an empty summary.
  FALLBACK_SUMMARY_LENGTH = 300

  class << self
    def parse(text)
      text = text.to_s
      Result.new(summary: summary(text), contexts: blocks(text, CONTEXT), missing: blocks(text, MISSING))
    end

    private

    def summary(text)
      text[SUMMARY, 1].to_s.strip.presence || prose(text).strip[0, FALLBACK_SUMMARY_LENGTH]
    end

    # The reply without its blocks, tags and contents both.
    def prose(text)
      [ SUMMARY, CONTEXT, MISSING ].reduce(text) { |rest, block| rest.gsub(block, "") }
    end

    # A block with nothing in it says nothing, and is dropped.
    def blocks(text, pattern)
      text.scan(pattern).map { |(body)| body.strip }.reject(&:empty?)
    end
  end
end
