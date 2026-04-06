class TimesheetsController < ApplicationController
  include WorkspaceScoped

  before_action :require_employee!

  def show
    @week_start = if params[:week_of]
      Date.parse(params[:week_of]).beginning_of_week(:monday)
    else
      Date.current.beginning_of_week(:monday)
    end

    @week_days = (0..6).map { |i| @week_start + i.days }

    @entries = current_workspace.time_entries
      .where(user: current_user)
      .completed
      .in_range(@week_start.beginning_of_day, (@week_start + 6.days).end_of_day)
      .includes(:project, :task)

    # Build grid data: { [project_id, task_id] => { date => seconds } }
    @grid = {}
    @entries.each do |entry|
      key = [ entry.project_id, entry.task_id ]
      @grid[key] ||= {}
      date = entry.started_at.to_date
      @grid[key][date] = (@grid[key][date] || 0) + entry.duration_seconds
    end

    # Build rows from actual entries (not from available_projects)
    @rows = @grid.keys.map { |project_id, task_id|
      entry = @entries.detect { |e| e.project_id == project_id && e.task_id == task_id }
      { project: entry.project, task: entry.task, key: [project_id, task_id] }
    }

    # Entry details grouped by [project_id, task_id] for expanded view
    @entry_details = {}
    @entries.each do |entry|
      key = [ entry.project_id, entry.task_id ]
      @entry_details[key] ||= []
      @entry_details[key] << entry
    end

    # Daily totals
    @day_totals = {}
    @week_days.each do |day|
      @day_totals[day] = @entries.select { |e| e.started_at.to_date == day }.sum(&:duration_seconds)
    end
  end

  def update_cell
    project_id = params[:project_id]

    unless current_user.admin_or_owner?(current_workspace)
      unless ProjectMembership.exists?(project_id: project_id, user_id: current_user.id)
        redirect_to timesheet_path, alert: "You are not assigned to this project."
        return
      end
    end

    task_id = params[:task_id].presence
    date = Date.parse(params[:date])
    duration_str = params[:duration]

    duration_seconds = parse_timesheet_duration(duration_str)

    # Find existing entry for this project/task/date
    existing = current_workspace.time_entries
      .where(user: current_user, project_id: project_id, task_id: task_id)
      .for_date(date)
      .completed
      .first

    if duration_seconds.nil? || duration_seconds <= 0
      existing&.destroy
    elsif existing
      existing.update!(
        stopped_at: existing.started_at + duration_seconds.seconds,
        duration_seconds: duration_seconds
      )
    else
      current_workspace.time_entries.create!(
        user: current_user,
        project_id: project_id,
        task_id: task_id,
        started_at: date.to_datetime.change(hour: 9),
        stopped_at: date.to_datetime.change(hour: 9) + duration_seconds.seconds,
        duration_seconds: duration_seconds
      )
    end

    redirect_to timesheet_path(week_of: date.beginning_of_week(:monday))
  end

  private

  def parse_timesheet_duration(str)
    return nil if str.blank?

    if str.match?(/\A\d+:\d{2}\z/)
      parts = str.split(":").map(&:to_i)
      parts[0] * 3600 + parts[1] * 60
    elsif str.match?(/\A\d+\.?\d*\z/)
      (str.to_f * 3600).to_i
    end
  end
end
