class TimersController < ApplicationController
  include WorkspaceScoped

  before_action { require_product!(:time_hr) }

  before_action :require_employee!

  def start
    existing = current_user.running_timer(current_workspace)
    if existing
      existing.update!(stopped_at: Time.current)
    end

    project = current_workspace.projects.find(params[:project_id]) if params[:project_id].present?

    unless current_user.admin_or_owner?(current_workspace) || project.nil?
      unless ProjectMembership.exists?(project: project, user: current_user)
        redirect_back fallback_location: root_path, alert: "You are not assigned to this project."
        return
      end
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

    timer&.update!(running_timer_attributes(timer))

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
    params.require(:time_entry).permit(:description, :project_id, :task_id, :started_at)
  end

  def running_timer_attributes(timer)
    attrs = timer_params.to_h

    if attrs.key?("started_at")
      moved = parse_start_time(attrs.delete("started_at"))
      attrs["started_at"] = moved if moved
    end

    # The timer bar submits the moment the project select changes, while the new
    # project's task list is still loading — so the task_id riding along still
    # belongs to the PREVIOUS project. Drop it rather than saving an entry whose
    # task sits in a different project than the entry does.
    if attrs["task_id"].present?
      project_id = attrs["project_id"].presence || timer.project_id
      in_project = project_id.present? &&
        Task.joins(:project)
            .where(projects: { workspace_id: current_workspace.id })
            .exists?(id: attrs["task_id"], project_id: project_id)

      unless in_project
        attrs["task_id"] = nil
      end
    end

    attrs
  end

  # Correcting a forgotten start ("I actually began at 14:05"). Refuses anything
  # unparseable or in the future — a start ahead of now makes the running
  # counter tick backwards.
  def parse_start_time(value)
    return nil if value.blank?

    parsed = Time.zone.parse(value.to_s)
    return nil if parsed.nil? || parsed > Time.current

    parsed
  rescue ArgumentError
    nil
  end
end
