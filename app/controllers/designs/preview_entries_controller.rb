# The lasting links to a project's designs (Designs::Publisher#url):
# /<organization>/<project>/design/<page> for its approved designs (master),
# and /<project>/<KEY>/… for a task's, the ones tickets and Jira carry (#short).
# Whoever opens one signs in, and must be someone the Workshop shows that
# project to; they are then sent on to the same page under a short-lived
# grant, where it runs sandboxed (Designs::PreviewsController). The query,
# contexts and all, goes along.
class Designs::PreviewEntriesController < ApplicationController
  CHANGES_PAGE = "__flosis/changes.html".freeze
  WIP = "wip".freeze

  def master
    open_preview(Designs::Repo::MASTER)
  end

  # A task's designs by its project and key, no organization (Kacper,
  # 2026-11-23): /<project>/<KEY> opens its last accepted version, else its
  # work in progress; /<project>/<KEY>/wip always the work in progress, the
  # link to send someone; then <context>/<screen> for a screen, or a path. The
  # project is looked for in each of the reader's organizations: the same name
  # and key found twice asks which, and ?in=<project id> names it.
  def short
    found = short_matches
    return head(:not_found) if found.empty?
    return choose(found) if found.size > 1

    project, slot = found.first
    open_preview(slot, project, short_page)
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

  def open_preview(slot, project = named_project, page = asked_page)
    publisher = project && Designs::Publisher.new(project, nil)
    return head(:not_found) unless publisher&.published?(slot)

    # A version with a list of what changed opens on it (2026-11-21).
    page = CHANGES_PAGE if page.empty? && publisher.slot_folder(slot)&.join(CHANGES_PAGE)&.file?
    target = publisher.grant_url(slot, page)
    query = passed_query
    target = "#{target}?#{query}" if query.present?
    # The host is the app's own, from DESIGNS_PREVIEW_URL.
    redirect_to target, allow_other_host: true
  rescue ArgumentError
    head :not_found
  end

  # The page as asked. Rails takes a folder's slash off request.path before
  # routing; the path as asked keeps it.
  def asked_page
    page = params[:path].to_s
    page.present? && slashed? ? "#{page}/" : page
  end

  def slashed?
    request.original_fullpath.split("?", 2).first.end_with?("/")
  end

  # The query that goes along to the page: all of it but which project.
  def passed_query
    request.query_string.split("&").reject { |pair| pair.start_with?("in=") }.join("&")
  end

  # [project, slot] for each project of that name, in each of the reader's
  # organizations, that has something published for the key; only the one
  # ?in= names when it does.
  def short_matches
    Current.user.workspaces.order(:name).flat_map do |workspace|
      Project.workshop_visible_to(Current.user, workspace).filter_map do |project|
        next unless Designs::Publisher.label(project.name, "project") == params[:project]
        next if params[:in].present? && project.id.to_s != params[:in].to_s

        slot = short_slot(project)
        [ project, slot ] if slot
      end
    end
  end

  # What a task's link opens: with /wip its design thread's branch while it is
  # published; else its designs' last accepted copy (2026-11-21), else that
  # branch (Workshop Designs v2), else the slot of the key's name. It goes
  # through the task's merges, so it outlives the thread. Nil when none of it
  # is published.
  def short_slot(project)
    key = params[:key]
    task = key.start_with?("task-") ? project.tasks.find_by(id: key.delete_prefix("task-")) : project.tasks.find_by(external_reference: key)
    publisher = Designs::Publisher.new(project, nil)
    branch = task&.design_thread&.branch.presence
    return branch if wip? && branch && publisher.published?(branch)

    slot = (task && (Designs::AcceptedScreens.new(task).slot || branch)) || key
    slot if publisher.published?(slot)
  rescue ArgumentError
    nil
  end

  def wip?
    params[:path].to_s.split("/").first == WIP
  end

  # The page a task's link names: <context>/<screen> is a screen (two names,
  # no dot in either), anything else a path inside the version, nothing the
  # version itself.
  def short_page
    segments = params[:path].to_s.split("/")
    segments.shift if wip?
    if segments.size == 2 && segments.none? { |segment| segment.include?(".") } && !slashed?
      "designs/#{segments.join("/")}.html"
    else
      page = segments.join("/")
      page.present? && slashed? ? "#{page}/" : page
    end
  end

  # The same project name and key found twice: they pick one, and its link
  # says which with ?in= (Kacper, 2026-11-23: "rzadkość"). The link is built
  # from what the route read, never the path as asked, which may start with //.
  def choose(found)
    segments = [ params[:project], params[:key], *params[:path].to_s.split("/") ]
    path = "/#{segments.map { |segment| CGI.escapeURIComponent(segment) }.join("/")}#{'/' if params[:path].present? && slashed?}"
    query = passed_query.split("&")
    @choices = found.map do |project, _|
      { organization: project.workspace.name, project: project.name, href: "#{path}?#{(query + [ "in=#{project.id}" ]).join("&")}" }
    end
    render :choose
  end

  def shown?(project)
    workspace = Current.user.workspaces.find_by(id: project.workspace_id)
    workspace.present? && Project.workshop_visible_to(Current.user, workspace).exists?(id: project.id)
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
