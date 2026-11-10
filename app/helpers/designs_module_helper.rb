# What the Designs module's views share (Workshop Designs v2): the icons of
# Kacper's design (ClearBacklog-3.html), stroked like the rest of Clar, and the
# names people read for contexts and screens.
module DesignsModuleHelper
  DESIGNS_ICONS = {
    pen: '<path d="M12 19l7-7 3 3-7 7-3-3z"/><path d="M18 13l-1.5-7.5L2 2l3.5 14.5L13 18l5-5z"/><path d="M2 2l7.586 7.586"/><circle cx="11" cy="11" r="2"/>',
    branch: '<line x1="6" y1="3" x2="6" y2="15"/><circle cx="18" cy="6" r="3"/><circle cx="6" cy="18" r="3"/><path d="M18 9a9 9 0 0 1-9 9"/>',
    merge: '<circle cx="18" cy="18" r="3"/><circle cx="6" cy="6" r="3"/><path d="M6 21V9a9 9 0 0 0 9 9"/>',
    ai: '<path d="M12 2l2.4 7.4H22l-6 4.6 2.3 7.4L12 17l-6.3 4.4L8 14 2 9.4h7.6z"/>',
    lock: '<rect x="3" y="11" width="18" height="11" rx="2"/><path d="M7 11V7a5 5 0 0 1 10 0v4"/>',
    folder: '<path d="M22 19a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h5l2 3h9a2 2 0 0 1 2 2z"/>',
    task: '<path d="M9 11l3 3 8-8"/><path d="M20 12v6a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2h9"/>',
    check: '<path d="M20 6L9 17l-5-5"/>',
    gear: '<circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.6 1.6 0 0 0 .3 1.8l.1.1a2 2 0 1 1-2.8 2.8l-.1-.1a1.6 1.6 0 0 0-2.7 1.1V21a2 2 0 1 1-4 0v-.1A1.6 1.6 0 0 0 7 19.4l-.1.1a2 2 0 1 1-2.8-2.8l.1-.1A1.6 1.6 0 0 0 3 14.6H3a2 2 0 1 1 0-4h.1A1.6 1.6 0 0 0 4.6 8L4.5 8a2 2 0 1 1 2.8-2.8l.1.1A1.6 1.6 0 0 0 10 4.6V4a2 2 0 1 1 4 0v.1a1.6 1.6 0 0 0 2.7 1.1l.1-.1a2 2 0 1 1 2.8 2.8l-.1.1a1.6 1.6 0 0 0 1.1 2.7H21a2 2 0 1 1 0 4h-.1a1.6 1.6 0 0 0-1.5 1z"/>',
    panel: '<rect x="3" y="3" width="18" height="18" rx="2"/><path d="M9 3v18"/>',
    plus: '<path d="M12 5v14M5 12h14"/>',
    back: '<path d="M15 18l-6-6 6-6"/>',
    next: '<path d="M9 6l6 6-6 6"/>',
    close: '<path d="M18 6L6 18M6 6l12 12"/>',
    trash: '<path d="M3 6h18"/><path d="M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6"/><path d="M8 6V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2"/>',
    external: '<path d="M18 13v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h6"/><path d="M15 3h6v6"/><path d="M10 14L21 3"/>',
    attach: '<path d="M21.4 11.1l-9.2 9.2a6 6 0 0 1-8.5-8.5l9.2-9.2a4 4 0 0 1 5.7 5.7l-9.2 9.2a2 2 0 0 1-2.8-2.8l8.5-8.5"/>',
    send: '<path d="M22 2L11 13M22 2l-7 20-4-9-9-4z"/>',
    down: '<path d="M6 9l6 6 6-6"/>',
    up: '<path d="M18 15l-6-6-6 6"/>',
    palette: '<circle cx="13.5" cy="6.5" r="2.5"/><circle cx="17.5" cy="10.5" r="2.5"/><circle cx="8.5" cy="7.5" r="2.5"/><circle cx="6.5" cy="12.5" r="2.5"/><path d="M12 2a10 10 0 1 0 0 20c1.1 0 2-.9 2-2 0-.5-.2-1-.5-1.3-.3-.4-.5-.8-.5-1.3 0-1.1.9-2 2-2h2.3A5.6 5.6 0 0 0 22 9.8C22 5.5 17.5 2 12 2z"/>',
    grid: '<rect x="3" y="3" width="7" height="7" rx="1"/><rect x="14" y="3" width="7" height="7" rx="1"/><rect x="3" y="14" width="7" height="7" rx="1"/><rect x="14" y="14" width="7" height="7" rx="1"/>',
    reload: '<path d="M3 12a9 9 0 1 0 3-6.7"/><path d="M3 3v5h5"/>',
    stop: '<rect x="6" y="6" width="12" height="12" rx="2"/>'
  }.freeze

  def designs_icon(name, size = 16)
    tag.svg(DESIGNS_ICONS.fetch(name).html_safe, width: size, height: size, viewBox: "0 0 24 24", fill: "none",
            stroke: "currentColor", "stroke-width": 2, "stroke-linecap": "round", "stroke-linejoin": "round", "aria-hidden": true)
  end

  # How long a turn has taken, as the chat says it: seconds under a minute,
  # whole minutes after.
  def designs_duration(seconds)
    seconds = [ seconds.to_i, 0 ].max
    seconds < 60 ? "#{seconds} s" : "#{seconds / 60} min"
  end

  def designs_context_name(contexts, id)
    contexts.find { |context| context[:id] == id }&.dig(:name) || id.to_s.humanize
  end

  def designs_screen_name(screens, context, id)
    screens.find { |screen| screen[:context] == context && screen[:id] == id }&.dig(:name) || id.to_s.humanize
  end

  def designs_initials(name)
    name.to_s.split.map(&:first).first(2).join.upcase.presence || "?"
  end

  def designs_ago(time)
    return "" unless time

    seconds = Time.current - time
    seconds < 60 ? "just now" : "#{time_ago_in_words(time)} ago"
  end

  # What Delete on a thread's row asks first: where its branch goes, and for
  # how long it can come back.
  def designs_delete_confirm(thread)
    return %(Delete "#{thread.title}"?) if thread.fresh?

    %(Delete "#{thread.title}"? Its branch #{thread.branch} moves to #{Designs::Threads::ARCHIVE} on GitHub, ) +
      "and you can restore the thread for #{DesignThread::KEPT.in_days.to_i} days."
  end
end
