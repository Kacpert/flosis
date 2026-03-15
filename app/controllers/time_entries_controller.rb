class TimeEntriesController < ApplicationController
  include WorkspaceScoped

  before_action :require_employee!
  before_action :set_time_entry, only: %i[edit update destroy]

  def index
    @date = params[:date] ? Date.parse(params[:date]) : Date.current
    scope = current_workspace.time_entries
      .where(user: current_user)
      .completed
      .includes(:project, :task, :tags)

    if params[:project_id].present?
      scope = scope.where(project_id: params[:project_id])
    end

    if params[:tag_id].present?
      scope = scope.joins(:time_entry_tags).where(time_entry_tags: { tag_id: params[:tag_id] })
    end

    # Show a week of entries around the selected date
    week_start = @date.beginning_of_week(:monday)
    week_end = @date.end_of_week(:monday)
    @entries = scope.in_range(week_start.beginning_of_day, week_end.end_of_day)
      .order(started_at: :desc)

    @entries_by_day = @entries.group_by { |e| e.started_at.to_date }
    @projects = available_projects
    @tags = current_workspace.tags.order(:name)
    @new_entry = current_workspace.time_entries.build(started_at: Time.current, user: current_user)
  end

  def new
    @time_entry = current_workspace.time_entries.build(started_at: Time.current, user: current_user)
    @projects = available_projects
    @tags = current_workspace.tags.order(:name)
  end

  def create
    @time_entry = current_workspace.time_entries.build(time_entry_params)
    @time_entry.user = current_user

    handle_manual_duration

    if @time_entry.save
      respond_to do |format|
        format.turbo_stream { redirect_to time_entries_path(date: @time_entry.started_at.to_date) }
        format.html { redirect_to time_entries_path(date: @time_entry.started_at.to_date), notice: "Time entry created." }
      end
    else
      @projects = available_projects
      @tags = current_workspace.tags.order(:name)
      render :new, status: :unprocessable_entity
    end
  end

  def edit
    @projects = available_projects
    @tags = current_workspace.tags.order(:name)
  end

  def update
    handle_manual_duration

    if @time_entry.update(time_entry_params)
      respond_to do |format|
        format.turbo_stream do
          render turbo_stream: turbo_stream.replace(
            "time_entry_#{@time_entry.id}",
            partial: "time_entries/time_entry_row",
            locals: { entry: @time_entry }
          )
        end
        format.html { redirect_to time_entries_path(date: @time_entry.started_at.to_date), notice: "Time entry updated." }
      end
    else
      respond_to do |format|
        format.turbo_stream do
          render turbo_stream: turbo_stream.replace(
            "time_entry_#{@time_entry.id}",
            partial: "time_entries/time_entry_row",
            locals: { entry: @time_entry, editing: true }
          )
        end
        format.html do
          @projects = available_projects
          @tags = current_workspace.tags.order(:name)
          render :edit, status: :unprocessable_entity
        end
      end
    end
  end

  def destroy
    date = @time_entry.started_at.to_date
    @time_entry.destroy
    redirect_to time_entries_path(date: date), notice: "Time entry deleted.", status: :see_other
  end

  def bulk_update
    ids = params[:time_entry_ids] || []
    entries = current_workspace.time_entries.where(id: ids, user: current_user)

    case params[:bulk_action]
    when "change_project"
      entries.update_all(project_id: params[:project_id].presence, task_id: nil)
    else
      entries.each { |entry| entry.update(bulk_params) }
    end

    redirect_to time_entries_path, notice: "#{entries.size} entries updated."
  end

  def bulk_destroy
    ids = params[:time_entry_ids] || []
    entries = current_workspace.time_entries.where(id: ids, user: current_user)
    count = entries.destroy_all.size
    redirect_to time_entries_path, notice: "#{count} entries deleted."
  end

  private

  def set_time_entry
    @time_entry = current_workspace.time_entries.where(user: current_user).find(params[:id])
  end

  def time_entry_params
    params.require(:time_entry).permit(:description, :project_id, :task_id, :started_at, :stopped_at,
                                       tag_ids: [])
  end

  def bulk_params
    params.permit(:project_id)
  end

  def handle_manual_duration
    if params[:time_entry][:duration_manual].present?
      duration = parse_duration(params[:time_entry][:duration_manual])
      if duration && @time_entry.started_at
        @time_entry.stopped_at = @time_entry.started_at + duration.seconds
      end
    end
  end

  def parse_duration(str)
    if str.match?(/\A\d{1,3}:\d{2}(:\d{2})?\z/)
      parts = str.split(":").map(&:to_i)
      hours, minutes, seconds = parts[0], parts[1], parts[2] || 0
      return nil if minutes >= 60 || seconds >= 60
      total = hours * 3600 + minutes * 60 + seconds
      total > 0 && total <= 86400 ? total : nil
    elsif str.match?(/\A\d{1,2}\.\d{1,2}\z/)
      total = (str.to_f * 3600).to_i
      total > 0 && total <= 86400 ? total : nil
    elsif str.match?(/\A\d{1,3}\z/)
      # Plain number: treat as minutes (max 480 = 8 hours)
      minutes = str.to_i
      minutes > 0 && minutes <= 480 ? minutes * 60 : nil
    end
  end
end
