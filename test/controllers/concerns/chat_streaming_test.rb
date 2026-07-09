require "test_helper"

# Unit test for ChatStreaming#handle_stream_line — the parser that turns raw
# Claude CLI stream-json lines into SSE chunks. The bug it guards: when the AI
# calls a tool (Read/Grep) WITHOUT preceding narration text, the old code
# emitted nothing (it filter-mapped only text blocks), so the user saw frozen
# "thinking…" dots and — because nothing streamed — got no "Show thinking"
# toggle afterward. tool_use blocks must now stream a short narration line.
class ChatStreamingTest < ActiveSupport::TestCase
  # Minimal host for the concern: a real controller (so ActionController::Live /
  # rescue_from resolve) that captures SSE writes and accumulates chunks,
  # mirroring how the real controllers drive handle_stream_line.
  class Harness < ActionController::Base
    include ChatStreaming
    CHAT_PURPOSE = "test".freeze

    attr_reader :writes, :chunks

    def initialize
      super
      @writes = []
      @chunks = []
    end

    # Stub the ActionController::Live stream with a capture object.
    def response
      @response ||= Struct.new(:stream).new(StreamCapture.new(@writes))
    end

    class StreamCapture
      def initialize(sink) = @sink = sink
      def write(s) = @sink << s
    end

    def run(line, final_done: false)
      handle_stream_line(line, final_done: final_done) { |c| @chunks << c }
    end
  end

  def assistant_line(*blocks)
    { "type" => "assistant", "message" => { "content" => blocks } }.to_json
  end

  def data_payloads(writes)
    writes.select { |w| w.start_with?("data: ") }
          .map { |w| JSON.parse(w.delete_prefix("data: ").strip) }
  end

  test "a tool_use block with NO text still streams a narration line" do
    h = Harness.new
    h.run(assistant_line(
      { "type" => "tool_use", "name" => "Read", "input" => { "file_path" => "/x/CLAUDE.md" } }
    ))

    # Something must be streamed (previously: nothing).
    assert h.chunks.any?, "tool_use must yield a chunk so the toggle has content"
    joined = h.chunks.join
    assert_includes joined, "CLAUDE.md", "narration should name what's being read"
    # And it must reach the SSE stream as a data: string payload.
    payloads = data_payloads(h.writes)
    assert payloads.any? { |p| p.is_a?(String) && p.include?("CLAUDE.md") }
  end

  test "text blocks still stream as before" do
    h = Harness.new
    h.run(assistant_line({ "type" => "text", "text" => "Here's my take." }))
    assert_equal "Here's my take.", h.chunks.join
  end

  test "a text block followed by a tool_use streams both, separated" do
    h = Harness.new
    h.run(assistant_line(
      { "type" => "text", "text" => "Let me check the ticket." },
      { "type" => "tool_use", "name" => "Read", "input" => { "file_path" => "/x/attachment.pdf" } }
    ))
    joined = h.chunks.join
    assert_includes joined, "Let me check the ticket."
    assert_includes joined, "attachment.pdf"
  end

  test "consecutive assistant turns are separated by a blank line" do
    h = Harness.new
    h.run(assistant_line({ "type" => "text", "text" => "First." }))
    h.run(assistant_line({ "type" => "text", "text" => "Second." }))
    assert_equal "First.\n\nSecond.", h.chunks.join
  end

  test "a Grep tool_use narrates the search, not a file read" do
    h = Harness.new
    h.run(assistant_line(
      { "type" => "tool_use", "name" => "Grep", "input" => { "pattern" => "hint:" } }
    ))
    assert_includes h.chunks.join.downcase, "search"
  end

  # The reported bug end-to-end: the AI investigates (tool calls, little/no
  # narration text) then answers. Because tool_use now streams, the accumulated
  # "streamed" text differs from the clean "answer", so thinking_for returns
  # non-nil and the "Show thinking" toggle renders (it was nil → no toggle).
  test "investigate-then-answer produces non-nil thinking so the toggle renders" do
    h = Harness.new
    # Turn 1: straight to a tool call (no narration text — the failure case).
    h.run(assistant_line({ "type" => "tool_use", "name" => "Read", "input" => { "file_path" => "/app/CLAUDE.md" } }))
    # Turn 2: another read.
    h.run(assistant_line({ "type" => "tool_use", "name" => "Read", "input" => { "file_path" => "/app/models/candidate.rb" } }))
    # Turn 3: the actual answer.
    h.run(assistant_line({ "type" => "text", "text" => "This is worth building." }))

    streamed = h.chunks.join
    answer = "This is worth building."
    thinking = h.send(:thinking_for, streamed, answer)

    assert thinking.present?, "thinking must be non-nil so a Show-thinking toggle appears"
    assert_includes thinking, "CLAUDE.md"
    assert_includes thinking, "candidate.rb"
  end
end
