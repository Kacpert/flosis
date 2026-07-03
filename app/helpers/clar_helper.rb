# View helpers for the Clar workshop shell (layout, top bar, sidebar).
module ClarHelper
  AVATAR_PALETTE = %w[#4f46e5 #0d9488 #db2777 #d97706 #7c3aed].freeze

  # "Mara Okafor" -> "MO", "Alex" -> "A". Max 2 letters, uppercase.
  def clar_initials(name)
    return "" if name.blank?

    name.to_s.split(" ").map { |w| w[0] }.compact.first(2).join.upcase
  end

  # Deterministic palette color for a given seed (name, id, etc.) so the same
  # person/entity always renders with the same avatar color.
  def clar_avatar_color(seed)
    index = Digest::MD5.hexdigest(seed.to_s).to_i(16) % AVATAR_PALETTE.size
    AVATAR_PALETTE[index]
  end

  # Tailwind arbitrary-value bg class for the same deterministic palette
  # (avoids a raw inline style attribute wherever an avatar needs the color).
  def clar_avatar_bg_class(seed)
    "bg-[#{clar_avatar_color(seed)}]"
  end

  # "4 min ago" / "2h ago" / "3d ago" style relative time for the Claude
  # status card and similar spots. Falls back to nil-safe handling.
  def clar_time_ago(time)
    return nil if time.blank?

    seconds = (Time.current - time).to_i
    seconds = 0 if seconds.negative?

    case seconds
    when 0...60
      "just now"
    when 60...3600
      "#{seconds / 60} min ago"
    when 3600...86400
      "#{seconds / 3600}h ago"
    else
      "#{seconds / 86400}d ago"
    end
  end

  # Sets the flash-based Clar toast, read by clar_toast_controller.js on the
  # next page render.
  def clar_toast(message)
    flash[:clar_toast] = message
  end

  # Text color utility for the Jira board browser's TYPE dot/label
  # (Story/Task/Bug on Task#issue_type). Falls back to muted for anything else.
  def issue_type_color_class(issue_type)
    case issue_type
    when "Bug"  then "text-[color:var(--danger)]"
    when "Task" then "text-[color:var(--primary)]"
    when "Story" then "text-[color:var(--success)]"
    else "clar-text-muted"
    end
  end

  # Dot/text color for the backlog grooming table's PRIORITY column.
  def priority_color_class(priority)
    case priority
    when "High"   then "text-[color:var(--danger)]"
    when "Medium" then "text-[color:var(--warn)]"
    else "clar-text-faint"
    end
  end
end
