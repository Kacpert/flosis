# What a person does to a design thread (Workshop Designs v2): start one, talk
# in it, stop a turn or try a failed one again, bring its task's description
# or master into it, merge it, and turn a thread with no task into one
# (Generate task). Each sends them back to the Designs module, where the
# thread shows what happened.
class Workshop::DesignThreadsController < Workshop::BaseController
  before_action { require_permission!(:designs) }
  include DesignsVisibility
  before_action :set_thread, except: %i[create start_from_task]

  def create
    thread = Designs::Threads.start!(project: current_workshop_project, user: current_user)
    redirect_to workshop_designs_overview_path(thread: thread.id)
  end

  # "Design with AI" on a task: its thread, started on the task's
  # description, or the one it already has. A project without designs is sent
  # to set them up first.
  def start_from_task
    project = current_workshop_project
    task = project.tasks.find(params[:id])
    unless project.designs_ready?
      flash[:clar_toast] = "Set up Designs for #{project.name} first"
      return redirect_to(workshop_designs_overview_path)
    end

    thread = task.design_thread
    unless thread
      thread = Designs::Threads.start_from_task!(task, user: current_user)
      flash[:clar_toast] = "Design thread started · #{thread.branch}"
    end
    redirect_to workshop_designs_overview_path(thread: thread.id)
  end

  def message
    text = params[:text].to_s.strip
    if text.present? && @thread.open?
      Designs::Threads.message!(@thread, user: current_user, text: text, context: params[:ctx].presence, screen: params[:screen].presence)
    end
    redirect_to workshop_designs_overview_path(thread: @thread.id, ctx: params[:ctx].presence, screen: params[:screen].presence)
  rescue Designs::Threads::Busy => e
    redirect_to workshop_designs_overview_path(thread: @thread.id), alert: e.message
  end

  def merge
    merge = Designs::Threads.merge!(@thread, user: current_user)
    flash[:clar_toast] = "Merged into master · #{merge.short_sha}"
    redirect_to workshop_designs_overview_path(tab: "history", merge: merge.id)
  rescue Designs::Threads::Busy, Designs::Threads::AlreadyMerged, Designs::Threads::NothingToMerge => e
    redirect_to workshop_designs_overview_path(thread: @thread.id), alert: e.message
  rescue Designs::Repo::Conflict
    redirect_to workshop_designs_overview_path(thread: @thread.id), alert: "Master changed the same lines. Update from master, then merge."
  rescue Designs::Repo::Diverged => e
    redirect_to workshop_designs_overview_path(thread: @thread.id), alert: e.message
  rescue GitRunner::Error => e
    redirect_to workshop_designs_overview_path(thread: @thread.id),
                alert: "The merge did not reach GitHub, so master stays as it was: #{e.message.to_s.lines.first.to_s.strip.truncate(200)}"
  end

  # Delete on a thread's row: the thread waits under Deleted, its branch in
  # the archive, and the person is back at the threads.
  def destroy
    Designs::Threads.delete!(@thread, user: current_user)
    flash[:clar_toast] = @thread.deleted? ? "Thread deleted · you can restore it for #{DesignThread::KEPT.in_days.to_i} days" : "Thread deleted"
    redirect_to workshop_designs_overview_path, status: :see_other
  rescue Designs::Threads::Busy, Designs::Threads::AlreadyMerged => e
    redirect_to workshop_designs_overview_path, alert: e.message, status: :see_other
  rescue GitRunner::Error => e
    redirect_to workshop_designs_overview_path, status: :see_other,
                alert: "The branch could not be moved to the archive on GitHub, so the thread stays: #{e.message.to_s.lines.first.to_s.strip.truncate(200)}"
  end

  # Restore under Deleted: the thread is open again, as it was.
  def restore
    Designs::Threads.restore!(@thread, user: current_user)
    flash[:clar_toast] = "Thread restored · #{@thread.branch}"
    redirect_to workshop_designs_overview_path(thread: @thread.id)
  rescue Designs::Threads::Busy, Designs::Threads::Gone => e
    redirect_to workshop_designs_overview_path, alert: e.message
  rescue GitRunner::Error => e
    redirect_to workshop_designs_overview_path,
                alert: "The branch could not come back on GitHub, so the thread stays deleted: #{e.message.to_s.lines.first.to_s.strip.truncate(200)}"
  end

  # Try again, under a turn that failed: its request runs once more.
  def retry
    Designs::Threads.retry!(@thread, user: current_user)
    redirect_to workshop_designs_overview_path(thread: @thread.id)
  rescue Designs::Threads::Busy, ArgumentError => e
    redirect_to workshop_designs_overview_path(thread: @thread.id), alert: e.message
  end

  # Stop, on a turn that runs or waits.
  def stop
    Designs::Threads.stop!(@thread, turn_id: params[:turn], user: current_user)
    redirect_to workshop_designs_overview_path(thread: @thread.id)
  end

  def update_description
    Designs::Threads.update_description!(@thread, user: current_user)
    redirect_to workshop_designs_overview_path(thread: @thread.id, mode: "changes")
  end

  def update_master
    to = Designs::Repo.new(@thread.project).head(Designs::Repo::MASTER)
    Designs::Threads.update_master!(@thread, user: current_user)
    flash[:clar_toast] = "Updated from master · #{Designs::Threads.short(to)}"
    redirect_to workshop_designs_overview_path(thread: @thread.id, mode: "changes")
  rescue Designs::Threads::Busy, Designs::Repo::Diverged => e
    redirect_to workshop_designs_overview_path(thread: @thread.id), alert: e.message
  end

  def attach
    Designs::Threads.attach!(@thread, user: current_user, files: params[:files])
    redirect_to workshop_designs_overview_path(thread: @thread.id)
  rescue Designs::Threads::Busy, ArgumentError => e
    redirect_to workshop_designs_overview_path(thread: @thread.id), alert: e.message
  end

  def create_task
    title = params[:title].to_s.strip
    return redirect_to(workshop_designs_overview_path(thread: @thread.id), alert: "A task needs a title.") if title.blank?

    task = Designs::GeneratedTask.create!(@thread, user: current_user, title: title, description: params[:description].to_s)
    flash[:clar_toast] = "Task created · #{task.name} · Details Gathering"
    redirect_to workshop_idea_path(task)
  end

  private

  # A deleted thread only comes back; nothing else reaches it.
  def set_thread
    threads = current_workshop_project.design_threads
    @thread = (action_name == "restore" ? threads.deleted : threads.live).find(params[:id])
  end
end
