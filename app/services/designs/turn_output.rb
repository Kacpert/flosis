# Reads the reply Claude ends a design turn with (the protocol is in
# Designs::Prompt::BASE): one <summary> block, then any number of <context>
# blocks (a context it added) and <missing> blocks (a requirement the person
# has not decided). Text outside the blocks is not part of the result.
module Designs::TurnOutput
  Result = Data.define(:summary, :contexts, :missing)

  SUMMARY = %r{<summary>(.*?)</summary>}mi
  CONTEXT = %r{<context>(.*?)</context>}mi
  MISSING = %r{<missing>(.*?)</missing>}mi

  # A reply that ignores the protocol still has to say something in the chat
  # and in the commit message, so it is its own summary, cut short.
  FALLBACK_SUMMARY_LENGTH = 300

  class << self
    def parse(text)
      text = text.to_s
      Result.new(summary: summary(text), contexts: blocks(text, CONTEXT), missing: blocks(text, MISSING))
    end

    private

    def summary(text)
      text[SUMMARY, 1].to_s.strip.presence || text.strip[0, FALLBACK_SUMMARY_LENGTH]
    end

    # A block with nothing in it says nothing, and is dropped.
    def blocks(text, pattern)
      text.scan(pattern).map { |(body)| body.strip }.reject(&:empty?)
    end
  end
end
