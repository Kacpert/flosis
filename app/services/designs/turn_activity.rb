# What a design turn does while it runs, for the chat to show (Designs::
# TurnJob hands it each event the CLI streams): every step Claude takes, as
# { "at" => seconds into the turn, "kind" => the sort of step, "text" => what
# the chat says }. Files are named from the design repo's root, or as the
# app's; what Claude says between its steps is a step too, without its reply's
# blocks, which the chat gets as the reply. Its thinking reaches the stream
# empty, so it is not shown.
#
# The steps are saved on the turn at most every SAVE_EVERY seconds, and once
# more when the run is over: the chat polls the turn, and needs no write per
# event to see them come.
class Designs::TurnActivity
  # The most steps a turn keeps; past it, the first ones go.
  LIMIT = 400
  TEXT_LIMIT = 280
  SAVE_EVERY = 1.5
  # The reply's blocks, as Designs::TurnOutput reads them.
  REPLY_BLOCKS = %r{<(summary|context|missing|blocked|comes_in|kept|replaced)>.*?</\1>}m

  def initialize(turn, worktree:, app: nil, clock: Designs::TurnJob.clock)
    @turn = turn
    @worktree = worktree.to_s
    @app = app&.to_s
    @clock = clock
    @steps = Array(turn.activity)
  end

  # One event of the stream. A subagent's are not Claude's own steps.
  def record(event)
    return unless event.is_a?(Hash) && event["type"] == "assistant" && !event["parent_tool_use_id"]

    Array(event.dig("message", "content")).grep(Hash).each do |block|
      step = case block["type"]
             when "text" then said(block["text"])
             when "tool_use" then did(block["name"], block["input"].is_a?(Hash) ? block["input"] : {})
             end
      add(*step) if step
    end
    save if due?
  end

  # The steps go on the turn. They only show what it did, so a write that
  # fails is logged and never fails the turn.
  def save
    @saved_at = @clock.call
    @turn.update_columns(activity: @steps.last(LIMIT))
  rescue StandardError => e
    Rails.logger.warn("[#{self.class.name}] turn #{@turn.id}: could not save its steps: #{e.class}: #{e.message}")
  end

  private

  def add(kind, text)
    at = @turn.started_at ? (Time.current - @turn.started_at).to_i : 0
    @steps << { "at" => [ at, 0 ].max, "kind" => kind, "text" => text.truncate(TEXT_LIMIT) }
  end

  def said(text)
    text = text.to_s.gsub(REPLY_BLOCKS, " ").squish
    [ "say", text ] if text.present?
  end

  def did(name, input)
    case name
    when "Read" then [ "read", "Reading #{place(input["file_path"])}" ]
    when "Write" then [ "write", "Writing #{place(input["file_path"])}" ]
    when "Edit", "MultiEdit" then [ "edit", "Editing #{place(input["file_path"])}" ]
    when "Glob" then [ "find", "Looking for #{input["pattern"]}#{where(input["path"])}" ]
    when "Grep" then [ "search", "Searching for “#{input["pattern"].to_s.truncate(80)}”#{where(input["path"])}" ]
    else [ "other", "Using #{name}" ]
    end
  end

  # A file as the chat names it: from the design repo's root, or the app's.
  def place(path)
    path = path.to_s
    return path.delete_prefix("#{@worktree}/") if path.start_with?("#{@worktree}/")
    return "#{path.delete_prefix("#{@app}/")} in the app" if @app && path.start_with?("#{@app}/")

    path.split("/").last(3).join("/")
  end

  # Where a search looked, when not over the whole design repo.
  def where(path)
    path = path.to_s
    return "" if path.empty? || path == @worktree
    return " in the app" if @app && (path == @app || path.start_with?("#{@app}/"))

    " in #{place(path)}"
  end

  def due?
    @saved_at.nil? || @clock.call - @saved_at >= SAVE_EVERY
  end
end
