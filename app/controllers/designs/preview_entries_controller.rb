# The lasting links to a project's designs (Designs::Publisher#url):
# /<organization>/<project>/design/<page> for its approved designs (master),
# and /<organization>/<project>/<key>/design/<page> for a task's last approved
# version, the one Jira links to. Whoever opens one signs in, and must be
# someone the Workshop shows that project to; they are then sent on to the
# same page under a short-lived grant, where it runs sandboxed
# (Designs::PreviewsController). The query, contexts and all, goes along.
class Designs::PreviewEntriesController < ApplicationController
  def master
    open_preview(Designs::Repo::MASTER)
  end

  def task
    open_preview(params[:key])
  end

  private

  def open_preview(slot)
    project = named_project
    publisher = project && Designs::Publisher.new(project, nil)
    return head(:not_found) unless publisher&.published?(slot)

    page = params[:path].to_s
    # Rails takes a folder's slash off request.path before routing; the path as asked keeps it.
    page = "#{page}/" if page.present? && request.original_fullpath.split("?", 2).first.end_with?("/")
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
