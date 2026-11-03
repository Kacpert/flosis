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

  # Text color for the AI Alerts rules-list "last run" status chip
  # (AlertRule#last_run_status: :fired/:quiet are both green "ok" outcomes,
  # :error is red, :not_run and :logged — a rule that doesn't notify — are
  # neutral gray).
  # The topbar's integration chips. Each is one of three states:
  #   configured and its last health check passed → on (green)
  #   configured but the last check FAILED        → broken (red, reason on hover)
  #   not configured at all                       → neither (grey)
  #
  # Discord has no health check: a webhook URL is write-only, so there is
  # nothing to ask it. It reports configured-or-not, and says so on hover
  # rather than implying it was verified.
  #
  # Nothing selected means nothing to report: four grey chips claiming no
  # integration is connected would be a lie about a screen with no project on it.
  def integration_chips
    project = current_workshop_project
    return [] unless project

    [
      chip("Jira", configured: project.jira_connected?,
                   ok: project.jira_status_ok, error: project.jira_status_error),
      chip("GitHub", configured: project.github_repo.present?,
                     ok: project.github_status_ok, error: project.github_status_error),
      chip("Discord", configured: project.discord_webhooks.any?, ok: nil, error: nil,
                      unchecked_note: "not health-checked"),
      chip("Figma", configured: project.figma_read_enabled?,
                    ok: project.figma_status_ok, error: project.figma_status_error)
    ]
  end

  private

  def chip(label, configured:, ok:, error:, unchecked_note: "not checked yet")
    broken = configured.present? && ok == false

    title =
      if !configured.present? then "#{label} · not connected"
      elsif broken            then "#{label} · not working — #{error.presence || 'last check failed'}"
      elsif ok.nil?           then "#{label} · connected (#{unchecked_note})"
      else "#{label} · connected"
      end

    { label: label, on: configured.present?, broken: broken, title: title }
  end

  public

  def alert_last_run_color_class(status)
    case status
    when :fired, :quiet then "text-[color:var(--success)]"
    when :error then "text-[color:var(--danger)]"
    else "clar-text-faint"
    end
  end

  # Trend-card window label. `range` is always a count of MONTHS regardless of
  # the bucket size (weeks/fortnights/months/sprints) — see
  # Workshop::TrendControls.
  def clar_trend_range_label(range)
    case range
    when 1 then "Last month"
    when 12 then "Last 12 months"
    else range >= 24 ? "Last 2 years" : "Last #{range} months"
    end
  end

  # Reporting period tab labels (Task 7.1): "{Month YYYY}" for :month, the
  # active sprint's name (or "Sprint" fallback when there's no active sprint)
  # for :sprint.
  def period_label_for(kind, active_sprint: nil, month: nil)
    case kind
    when :month then (month || Time.current).strftime("%B %Y")
    when :sprint then active_sprint&.name || "Sprint"
    end
  end

  # Configuration > Users: [badge_class, label] for a project membership or a
  # ProjectAccess. The label is derived from the switches, so a set matching no
  # preset reads "Custom", and a row with every switch off reads "No access",
  # rather than either being rounded to the nearest role.
  def permission_role_badge(holder)
    permission_badge_for(holder.role_label)
  end

  # The same badge from a role name alone, for the Users grid's administrator
  # rows: their access is the workspace flag, so there is no row to read the
  # switches off and no reason to spend a query establishing what the loader
  # already said.
  def permission_badge_for(label)
    klass = case label
            when "Administrator" then "clar-badge-warn"
            when PermissionPreset::CUSTOM, PermissionPreset::NONE then "clar-badge-muted"
            else "clar-badge-primary"
            end
    [ klass, label ]
  end
end
