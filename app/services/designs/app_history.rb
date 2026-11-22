# The app's history for an import's turns (Kacper, 2026-11-22: "dobrze żeby
# miał po prostu dostęp do gita na środowisku i lokalnie pobranego projektu
# w ten sposób ma wszystko"): a bare, full clone of each app repository the
# setup form names, kept in the project's folder between imports and fetched
# at the start of each. The git tool (lib/designs_crawler/git.mjs) reads them
# for the turns, and Designs::AppChanges for what changed since the last
# import. Full clones: reading them needs neither the network nor a token.
# Cloning and fetching use the project's GitHub token through GitRunner, as
# Designs::AppRepos does. A repository that cannot be read is a note on the
# run, never a stop.
class Designs::AppHistory
  # [{ "repo", "branch", "error" }]: what the last fetch! could not read.
  attr_reader :failures

  def initialize(project)
    @project = project
    @failures = []
  end

  def root = Pathname(@project.designs_dir).join("app-history")

  # Where owner/name's clone is: by name, so that reordering the form's
  # repositories keeps them.
  def path(repo) = root.join("#{repo.parameterize}.git")

  # Clones or fetches each app repository, and returns [{ "repo", "branch",
  # "path", "sha" }] for those it read: sha is the branch's head (the default
  # branch's when the form names none).
  def fetch!(setup = nil)
    @failures = []
    FileUtils.mkdir_p(root)
    File.chmod(0o700, root)
    Designs::AppRepos.repos_of(@project).filter_map do |_role, name, branch|
      dir = path(name)
      dir.join("HEAD").file? ? update(dir) : clone(name, dir)
      { "repo" => name, "branch" => branch, "path" => dir.to_s, "sha" => head(name, branch) }
    rescue GitRunner::Error, SystemCallError => e
      reason = e.message.to_s.lines.last(2).join(" ").squish.truncate(200)
      @failures << { "repo" => name, "branch" => branch, "error" => reason }
      setup&.note!("Reading the history", "#{name}#{" @ #{branch}" if branch} could not be read: #{reason}")
      nil
    end
  end

  # { "owner/name" => path } for the clones that exist, for the git tool.
  def clones
    Designs::AppRepos.repos_of(@project).map(&:second).uniq.each_with_object({}) do |name, found|
      dir = path(name)
      found[name] = dir.to_s if dir.join("HEAD").file?
    end
  end

  # git on owner/name's clone, here and now, without the network.
  def git(repo, *args)
    GitRunner.run!(*args, chdir: path(repo).to_s)
  end

  # The branch's head, the default branch's when none is named.
  def head(repo, branch)
    git(repo, "rev-parse", branch ? "refs/heads/#{branch}" : "HEAD").strip
  end

  private

  def clone(name, dir)
    FileUtils.rm_rf(dir)
    GitRunner.run!("clone", "--quiet", "--bare", "--", Designs::AppRepos.url_for.call(name), dir.to_s, chdir: root.to_s, token: token)
    File.chmod(0o700, dir)
  end

  def update(dir)
    GitRunner.run!("fetch", "--quiet", "--prune", "origin", "+refs/heads/*:refs/heads/*", chdir: dir.to_s, token: token)
  end

  def token = ProjectCredentials.new(@project).github_token
end
