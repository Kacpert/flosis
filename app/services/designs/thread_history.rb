# The chat of a design thread before a message, for a turn that starts a new
# Claude session (2026-11-27): that turn no longer has the session that heard
# it. The person's messages and the replies the chat shows; Flosis's hidden
# requests, its notes and the turns' steps stay out. Past the limit, the
# oldest messages go first, whole.
module Designs::ThreadHistory
  LIMIT = 20_000
  CUT = "(Earlier messages left out.)".freeze
  PERSON = "The person".freeze
  REPLIES = { "summary" => "You", "missing" => "You asked", "blocked" => "You were blocked" }.freeze

  module_function

  # nil when nothing was said before the message.
  def text(chat_session, before:, limit: LIMIT)
    entries = chat_session.chat_messages.where("id < ?", before).order(:id).filter_map { |message| entry(message) }
    return if entries.empty?

    kept = entries.dup
    kept.shift while kept.any? && length(kept, cut: kept.size < entries.size) > limit
    return entries.join("\n\n") if kept.size == entries.size

    kept = [ entries.last.truncate(limit - CUT.length - 2) ] if kept.empty?
    [ CUT, *kept ].join("\n\n")
  end

  def entry(message)
    label = message.role == "user" ? (PERSON if message.kind.nil?) : REPLIES[message.kind]
    "#{label}: #{message.content.strip}" if label && message.content.present?
  end

  def length(entries, cut:)
    entries.sum(&:length) + 2 * (entries.size - 1) + (cut ? CUT.length + 2 : 0)
  end
end
