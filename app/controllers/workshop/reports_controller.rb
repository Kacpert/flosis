# Workshop Reporting (Task 7.1): throughput/cost dashboard. Builds a
# WorkshopReport (pure read model) from request params and hands it to the
# view. See app/services/workshop_report.rb + .superpowers/sdd/task-7.1-brief.md.
class Workshop::ReportsController < Workshop::BaseController
  include Workshop::TrendControls

  # The per-developer modal offers finer windows than the main trend card.
  DEV_MODAL_RANGES = [ 1, 2, 3, 6, 12, 24 ].freeze
  DEFAULT_DEV_MODAL_RANGE = 6

  def show
    @period = params[:period] == "sprint" ? :sprint : :month
    @gran = coerce_gran(params[:gran])
    @range = coerce_range(params[:range])
    @chart = coerce_chart(params[:chart])
    @month = parse_month(params[:month])

    @developer = find_developer(params[:developer])

    # Sprint-period navigation: the ‹ › arrows walk this ordered list. nil
    # selection = the most recent sprint (the list's last entry).
    @sprints = period_sprints
    @selected_sprint = find_sprint(params[:sprint]) || @sprints.last

    @report = WorkshopReport.new(project: current_workshop_project, period: @period,
                                 developer: @developer, month: @month, sprint: @selected_sprint)

    @metrics = @report.metrics
    @developers = @report.developers
    @trend = @report.trend(granularity: @gran, range: bucket_count(@gran, @range))
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

    @chart = coerce_chart(params[:chart])
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

  # Sprints the ‹ › arrows can navigate, oldest first — the same universe
  # WorkshopReport#trend_sprints uses (started + finished sprints with real
  # dates), so the period label always matches a real reporting window.
  def period_sprints
    return [] unless current_workshop_project

    JiraSprint.joins(:jira_board)
              .where(jira_boards: { project_id: current_workshop_project.id })
              .where(state: %w[active closed])
              .where.not(start_date: nil).where.not(end_date: nil)
              .order(start_date: :asc)
              .to_a
  end

  def find_sprint(id)
    return nil if id.blank?
    @sprints.find { |sprint| sprint.id.to_s == id.to_s }
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
