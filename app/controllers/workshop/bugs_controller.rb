# Bug Reporting (Task 8.2): stats + trend + bug analysis list. Reuses
# WorkshopReport (Task 7.1/8.1's #bugs_created flip + #bug_stats) for the
# stat cards and trend, then builds the "Bug analysis" list itself: recent
# Bugs merged from OPEN `tasks` and FIXED `delivered_issues`, joined to
# `bug_attributions` by jira_key (see app/services/workshop_report.rb and
# .superpowers/sdd/task-8.2-brief.md). Same gran/range coercion rules as
# Workshop::ReportsController so the trend card's controls behave identically.
class Workshop::BugsController < Workshop::BaseController
  MONTH_RANGES = [ 6, 12, 24 ].freeze
  SPRINT_RANGES = [ 8, 13, 26 ].freeze
  DEFAULT_MONTH_RANGE = 12
  DEFAULT_SPRINT_RANGE = 13

  BUG = "Bug".freeze
  LIST_LIMIT = 30

  def show
    @gran = params[:gran] == "sprints" ? "sprints" : "months"
    @range = coerce_range(@gran, params[:range])

    @report = WorkshopReport.new(project: current_workshop_project, period: :month)

    @bug_stats = @report.bug_stats
    @trend = @report.trend(granularity: @gran, range: @range)
    @bugs = bug_analysis_list
  end

  def analyze
    attribution = current_workshop_project.bug_attributions.find_by!(jira_key: params[:jira_key])

    BugAttributionJob.perform_later(current_workshop_project.id, attribution.jira_key)

    flash[:clar_toast] = "Analyzing…"
    redirect_to workshop_bugs_path
  end

  private

  def coerce_range(gran, raw_range)
    allowed = gran == "sprints" ? SPRINT_RANGES : MONTH_RANGES
    default = gran == "sprints" ? DEFAULT_SPRINT_RANGE : DEFAULT_MONTH_RANGE
    value = raw_range.to_i
    allowed.include?(value) ? value : default
  end

  # Merges OPEN Bugs (tasks) and FIXED Bugs (delivered_issues) by recency
  # (jira_created_at for open, resolved_at for fixed — whichever is more
  # recent activity for that row), then left-joins bug_attributions by
  # jira_key so rows without an attribution yet still render (no badge).
  def bug_analysis_list
    return [] unless current_workshop_project

    attributions = current_workshop_project.bug_attributions.index_by(&:jira_key)

    open_rows = current_workshop_project.tasks.where(issue_type: BUG).map do |task|
      {
        key: task.external_reference,
        title: task.name,
        recency: task.jira_created_at,
        attribution: attributions[task.external_reference]
      }
    end

    fixed_rows = current_workshop_project.delivered_issues.where(issue_type: BUG).map do |issue|
      {
        key: issue.jira_key,
        title: issue.title,
        recency: issue.resolved_at,
        attribution: attributions[issue.jira_key]
      }
    end

    (open_rows + fixed_rows)
      .sort_by { |row| row[:recency] || Time.at(0) }
      .reverse
      .first(LIST_LIMIT)
  end
end
