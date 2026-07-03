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
end
