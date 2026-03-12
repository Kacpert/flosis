class DashboardController < ApplicationController
  include WorkspaceScoped

  def show
    today = Date.current
    week_start = today.beginning_of_week(start_day)

    @today_entries = current_workspace.time_entries
      .where(user: current_user)
      .completed
      .for_date(today)
      .includes(:project, :task, :tags)
      .order(started_at: :desc)

    @today_seconds = @today_entries.sum(:duration_seconds)

    @week_entries = current_workspace.time_entries
      .where(user: current_user)
      .completed
      .in_range(week_start, today.end_of_day)

    @week_seconds = @week_entries.sum(:duration_seconds)
    @week_billable_seconds = @week_entries.billable.sum(:duration_seconds)

    last_week_start = week_start - 7.days
    last_week_end = week_start - 1.second
    @last_week_seconds = current_workspace.time_entries
      .where(user: current_user)
      .completed
      .in_range(last_week_start, last_week_end)
      .sum(:duration_seconds)

    @billable_amount = @week_entries.billable.sum("time_entries.duration_seconds * COALESCE(time_entries.hourly_rate_cents, 0) / 360000.0")

    @projects_breakdown = current_workspace.time_entries
      .where(user: current_user)
      .completed
      .for_date(today)
      .joins(:project)
      .group("projects.name", "projects.color")
      .sum(:duration_seconds)

    @active_projects_count = current_workspace.projects.active.count
  end

  private

  def start_day
    current_workspace.week_start == 0 ? :sunday : :monday
  end
end
