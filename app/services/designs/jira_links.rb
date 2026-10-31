# The Web links from a task's Jira issue to its approved designs: one to the
# overview, and one per screen of the task's manifest and context it is shown
# in. They are read from the task's design branch (the last approved work),
# written with the project's own Jira credentials, and never touch the
# description: Jira's sync rewrites that every few minutes.
#
# Each link is known by a stable globalId, so writing one again updates it,
# and a link Flosis made for a screen the designs no longer have is deleted.
#   flosis-design:<project id>:<slug>:index
#   flosis-design:<project id>:<slug>:<screen path>:<ctx joined by ,>
class Designs::JiraLinks
  NO_JIRA = "This project isn't connected to Jira.".freeze
  NO_ISSUE = "This task has no Jira issue yet.".freeze
  NO_DESIGNS = "This task has no approved designs yet.".freeze

  Link = Data.define(:global_id, :url, :title)

  def initialize(task)
    @task = task
    @project = task.project
  end

  # { ok:, error: }. Stops at the first write that fails and returns it.
  def sync!
    credentials = ProjectCredentials.new(@project)
    return failure(NO_JIRA) unless credentials.jira_configured?
    return failure(NO_ISSUE) unless Designs::BranchNames::JIRA_KEY.match?(@task.external_reference.to_s)

    links = build_links
    return failure(NO_DESIGNS) unless links

    client = JiraClient.new(domain: credentials.jira_site, email: credentials.jira_email,
                            api_token: credentials.jira_api_token)
    write(client, links)
  end

  private

  def issue_key
    @task.external_reference
  end

  def slug
    @slug ||= Designs::BranchNames.slug(@task)
  end

  def prefix
    "flosis-design:#{@project.id}:#{slug}:"
  end

  def write(client, links)
    links.each do |link|
      result = client.upsert_remote_link(issue_key: issue_key, global_id: link.global_id, url: link.url, title: link.title)
      return failure(result[:error]) unless result[:ok]
    end

    existing = client.remote_links(issue_key)
    return failure(existing[:error]) unless existing[:ok]

    wanted = links.map(&:global_id)
    existing[:global_ids].select { |id| id.start_with?(prefix) && !wanted.include?(id) }.each do |stale|
      result = client.delete_remote_link(issue_key: issue_key, global_id: stale)
      return failure(result[:error]) unless result[:ok]
    end
    { ok: true, error: nil }
  end

  # The overview and every screen-and-context link, from the design branch as
  # this clone has it after a fetch, else as origin has it; nil when the task
  # has no approved design.
  def build_links
    repo = Designs::Repo.new(@project)
    repo.ensure_clone!
    design = Designs::BranchNames.design(@task)
    ref = if repo.head(design)
      "refs/heads/#{design}"
    elsif repo.remote_head(design)
      "refs/remotes/origin/#{design}"
    end
    return unless ref

    branch = Designs::WorkingBranch.new(Designs::WorkingBranch::GitTree.new(repo: repo, ref: ref), slug)
    publisher = Designs::Publisher.new(@project, nil)
    overview = Link.new(global_id: "#{prefix}index", url: publisher.url(slug), title: "Design · #{slug} · overview")
    screens = branch.screens.flat_map { |screen| screen_links(screen, branch.dimensions, publisher) }
    [ overview, *screens ].uniq(&:global_id)
  end

  # One link per context the screen names (that value in place of its own
  # dimension's default), or one with the defaults when it names none that a
  # dimension has.
  def screen_links(screen, dimensions, publisher)
    defaults = dimensions.map { |dimension| dimension["default"] }
    variants = screen["contexts"].filter_map do |value|
      index = dimensions.index { |dimension| dimension["values"].any? { |option| option["id"] == value } }
      defaults.dup.tap { |ctx| ctx[index] = value } if index
    end
    variants = [ defaults ] if variants.empty?
    variants.map do |ctx|
      Link.new(global_id: "#{prefix}#{screen["path"]}:#{ctx.join(",")}",
               url: publisher.url(slug, screen["path"], ctx: ctx),
               title: "Design · #{screen["title"]} · #{context_names(ctx, dimensions)}")
    end
  end

  def context_names(ctx, dimensions)
    names = ctx.each_with_index.map do |value, index|
      dimensions[index]["values"].find { |option| option["id"] == value }&.fetch("name") || value
    end
    names.empty? ? "default" : names.join(" + ")
  end

  def failure(error)
    { ok: false, error: error }
  end
end
