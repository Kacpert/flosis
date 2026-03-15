class TimersController < ApplicationController
  include WorkspaceScoped

  before_action :require_employee!

  def start
    # Stop any existing running timer first
    existing = current_user.running_timer(current_workspace)
    if existing
      existing.update!(stopped_at: Time.current)
    end

    @time_entry = current_workspace.time_entries.create!(
      user: current_user,
      started_at: Time.current,
      description: params[:description],
      project_id: params[:project_id],
      task_id: params[:task_id],
      tag_ids: Array(params[:tag_ids])
    )

    redirect_back fallback_location: root_path
  end

  def update_running
    timer = current_user.running_timer(current_workspace)

    if timer
      timer.update!(timer_params)
    end

    redirect_back fallback_location: root_path
  end

  def stop
    timer = current_user.running_timer(current_workspace)

    if timer
      timer.update!(stopped_at: Time.current)
    end

    redirect_back fallback_location: root_path
  end

  def discard
    timer = current_user.running_timer(current_workspace)
    timer&.destroy

    redirect_back fallback_location: root_path
  end

  private

  def timer_params
    params.require(:time_entry).permit(:description, :project_id, :task_id)
  end
end
