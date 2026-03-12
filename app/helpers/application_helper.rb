module ApplicationHelper
  include Pagy::Frontend

  def format_duration(seconds)
    return "0:00" if seconds.nil? || seconds.zero?
    hours = seconds / 3600
    minutes = (seconds % 3600) / 60
    secs = seconds % 60
    if hours > 0
      format("%d:%02d:%02d", hours, minutes, secs)
    else
      format("%d:%02d", minutes, secs)
    end
  end

  def format_duration_hm(seconds)
    return "0h 0m" if seconds.nil? || seconds.zero?
    hours = seconds / 3600
    minutes = (seconds % 3600) / 60
    if hours > 0
      "#{hours}h #{minutes}m"
    else
      "#{minutes}m"
    end
  end

  def format_money(cents)
    return "$0.00" if cents.nil?
    "$#{'%.2f' % (cents / 100.0)}"
  end

  def nav_link(text, path, icon: nil)
    active = current_page?(path)
    css = active ? "bg-primary text-primary-content" : "hover:bg-base-200"

    link_to path, class: "flex items-center gap-3 px-3 py-2 rounded-lg text-sm font-medium #{css}" do
      raw(icon.to_s) + content_tag(:span, text)
    end
  end

  def project_color_dot(color)
    content_tag(:span, "", class: "project-color-dot", style: "background-color: #{color}")
  end
end
