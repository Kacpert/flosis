# The lasting links to a project's designs (Designs::Publisher#url):
# /<organization>/<project>/design/<page> for its approved designs (master),
# and /<organization>/<project>/<key>/design/<page> for a task's last approved
# version, the one Jira links to. Whoever opens one signs in, and must be
# someone the Workshop shows that project to; they are then sent on to the
# same page under a short-lived grant, where it runs sandboxed
# (Designs::PreviewsController). The query, contexts and all, goes along.
class Designs::PreviewEntriesController < ApplicationController
  CHANGES_PAGE = "__flosis/changes.html".freeze

  def master
    open_preview(Designs::Repo::MASTER)
  end

  # A task's lasting link: its designs' last accepted copy (2026-11-21), else
  # its design thread's branch (Workshop Designs v2), else the slot of that
  # name. It goes through the task's merges, so it outlives the thread.
  def task
    project = named_project
    open_preview(task_slot(project, params[:key]), project)
  end

  # A page whose grant ran out (Designs::PreviewsController#ran_out), at
  # /<organization>/<project>/<grant>/renew/<page>: someone the Workshop shows
  # the grant's project to gets a new grant for the same slot and page, work
  # in progress included, as the Designs screen would give them.
  def renew
    project, slot = Designs::PreviewGrant.read(params[:grant], ran_out: true)
    return head(:not_found) unless project && shown?(project)

    open_preview(slot, project)
  end

  private

  def open_preview(slot, project = named_project)
    publisher = project && Designs::Publisher.new(project, nil)
    return head(:not_found) unless publisher&.published?(slot)

    page = params[:path].to_s
    # Rails takes a folder's slash off request.path before routing; the path as asked keeps it.
    page = "#{page}/" if page.present? && request.original_fullpath.split("?", 2).first.end_with?("/")
    # A version with a list of what changed opens on it (2026-11-21).
    page = CHANGES_PAGE if page.empty? && publisher.slot_folder(slot)&.join(CHANGES_PAGE)&.file?
    target = publisher.grant_url(slot, page)
    target = "#{target}?#{request.query_string}" if request.query_string.present?
    # The host is the app's own, from DESIGNS_PREVIEW_URL.
    redirect_to target, allow_other_host: true
  rescue ArgumentError
    head :not_found
  end

  # The project the link names, among those the Workshop shows whoever opened
  # it, in the workspace the link names rather than the one they last chose.
  # Names are compared as links write them.
  def task_slot(project, key)
    return key unless project

    task = key.to_s.start_with?("task-") ? project.tasks.find_by(id: key.delete_prefix("task-")) : project.tasks.find_by(external_reference: key)
    return key unless task

    Designs::AcceptedScreens.new(task).slot || task.design_thread&.branch.presence || key
  end

  def shown?(project)
    workspace = Current.user.workspaces.find_by(id: project.workspace_id)
    workspace.present? && Project.workshop_visible_to(Current.user, workspace).exists?(id: project.id)
  end

  def named_project
    Current.user.workspaces.find_each do |workspace|
      next unless Designs::Publisher.label(workspace.name, "organization") == params[:organization]

      project = Project.workshop_visible_to(Current.user, workspace).find do |candidate|
        Designs::Publisher.label(candidate.name, "project") == params[:project]
      end
      return project if project
    end
    nil
  end
end
