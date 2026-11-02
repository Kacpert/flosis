# The Web links from a task's Jira issue to its designs (Workshop Designs v2):
# one to the designs of the task's thread, and one per screen the thread
# changed against master. They are lasting links (/<org>/<project>/<KEY>/
# design/…), which open the thread's branch for whoever may see the project;
# they are written with the project's own Jira credentials and never touch the
# description: Jira's sync rewrites that every few minutes.
#
# Each link is known by a stable globalId, so writing one again updates it,
# and a link Flosis made for a screen the thread no longer changes is deleted.
#   flosis-design:<project id>:<slug>:index
#   flosis-design:<project id>:<slug>:<screen path>
class Designs::JiraLinks
  NO_JIRA = "This project isn't connected to Jira.".freeze
  NO_ISSUE = "This task has no Jira issue yet.".freeze
  NO_DESIGNS = "This task has no design thread yet.".freeze

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

  # The thread's link and one per screen it changed, from its branch as this
  # clone has it after a fetch, else as origin has it; nil without a thread.
  def build_links
    thread = @task.design_thread
    return if thread.nil? || thread.fresh?

    repo = Designs::Repo.new(@project)
    repo.ensure_clone!
    ref = if repo.head(thread.branch)
      "refs/heads/#{thread.branch}"
    elsif repo.remote_head(thread.branch)
      "refs/remotes/origin/#{thread.branch}"
    end
    return unless ref

    at = ->(at_ref) { Designs::Screens.new(paths: repo.ls_files(at_ref, "designs/"), reader: ->(path) { repo.read_file(at_ref, path) }) }
    head = at.call(ref)
    publisher = Designs::Publisher.new(@project, nil)
    overview = Link.new(global_id: "#{prefix}index", url: publisher.url(slug), title: "Designs · #{thread.branch}")
    screens = Designs::Changes.new(base: at.call(thread.base_sha.presence || Designs::Repo::MASTER), head: head).changed.map do |change|
      screen = head.find(change[:context], change[:screen])
      Link.new(global_id: "#{prefix}#{screen[:path]}", url: publisher.url(slug, screen[:path]),
               title: "Design · #{change[:context].humanize} › #{screen[:name]}")
    end
    [ overview, *screens ]
  end

  def failure(error)
    { ok: false, error: error }
  end
end
