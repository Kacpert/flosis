# Workshop Reporting (Task 7.1): throughput/cost dashboard. Builds a
# WorkshopReport (pure read model) from request params and hands it to the
# view. See app/services/workshop_report.rb + .superpowers/sdd/task-7.1-brief.md.
class Workshop::ReportsController < Workshop::BaseController
  MONTH_RANGES = [ 6, 12, 24 ].freeze
  SPRINT_RANGES = [ 8, 13, 26 ].freeze
  DEFAULT_MONTH_RANGE = 12
  DEFAULT_SPRINT_RANGE = 13

  # The per-developer modal offers finer windows than the main trend card.
  DEV_MODAL_RANGES = [ 1, 2, 3, 6, 12, 24 ].freeze
  DEFAULT_DEV_MODAL_RANGE = 3

  def show
    @period = params[:period] == "sprint" ? :sprint : :month
    @gran = params[:gran] == "sprints" ? "sprints" : "months"
    @range = coerce_range(@gran, params[:range])
    @month = parse_month(params[:month])

    @developer = find_developer(params[:developer])

    @report = WorkshopReport.new(project: current_workshop_project, period: @period, developer: @developer, month: @month)

    @metrics = @report.metrics
    @developers = @report.developers
    @trend = @report.trend(granularity: @gran, range: @range)
    @delivered = @report.delivered

    @all_developers = current_workshop_project ? project_developers : User.none
  end

  # Lazy turbo-frame modal: one developer's throughput over a selectable window
  # (1m..2y from today). Scoped through project_developers so a user outside the
  # project 404s. Renders the two charts (points area + bugs created/solved) and
  # 3 stat cards summed over the window.
  def developer
    @developer = project_developers.find(params[:id])
    @range = DEV_MODAL_RANGES.include?(params[:range].to_i) ? params[:range].to_i : DEFAULT_DEV_MODAL_RANGE

    report = WorkshopReport.new(project: current_workshop_project, developer: @developer)
    @trend = report.trend(granularity: "months", range: @range)
    @points_total = @trend.sum { |p| p[:sp] }
    @bugs_created_total = @trend.sum { |p| p[:bugs_created] }
    @bugs_solved_total = @trend.sum { |p| p[:bugs_fixed] }

    render partial: "workshop/reports/developer_modal", layout: false
  end

  private

  # Parse a "YYYY-MM" month param into a Date at the 1st. Invalid/blank -> nil
  # (WorkshopReport then defaults to the current month). WorkshopReport also
  # clamps a future month, so no future-guard is needed here.
  def parse_month(raw)
    return nil if raw.blank?
    Date.strptime(raw.to_s, "%Y-%m")
  rescue ArgumentError, TypeError
    nil
  end

  def coerce_range(gran, raw_range)
    allowed = gran == "sprints" ? SPRINT_RANGES : MONTH_RANGES
    default = gran == "sprints" ? DEFAULT_SPRINT_RANGE : DEFAULT_MONTH_RANGE
    value = raw_range.to_i
    allowed.include?(value) ? value : default
  end

  def find_developer(id)
    return nil if id.blank? || id == "all"
    return nil unless current_workshop_project
    project_developers.find_by(id: id)
  end

  # Developers selectable in the developer clar-select: project members plus
  # anyone with a time entry or delivered_issues assignment on the project —
  # matches WorkshopReport#developers' own email-matching universe.
  def project_developers
    User.where(id: current_workshop_project.members.select(:id))
        .or(User.where(id: current_workshop_project.time_entries.select(:user_id)))
        .order(:name)
  end
end
