module HolidayRequestsHelper
  def holiday_status_style(status)
    case status
    when "pending"
      "background: color-mix(in srgb, var(--color-tertiary) 15%, transparent); color: var(--color-tertiary)"
    when "approved"
      "background: color-mix(in srgb, #4CAF50 15%, transparent); color: #4CAF50"
    when "cancelled"
      "background: color-mix(in srgb, var(--color-error) 15%, transparent); color: var(--color-error)"
    end
  end
end
