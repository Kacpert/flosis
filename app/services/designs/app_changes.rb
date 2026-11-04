require "find"

# What changed in the app since an import (Designs imports): for each app
# repository the setup form names, the diff from the commit the earlier import
# read it at to the one it is at now, written into the resync's folder
# (run_dir/changes), read-only, for the resync's turns to read. An import that
# recorded no commits (the first ones did not) is taken at the commit its
# branch had when that import started.
#
# The history comes from a bare, blobless clone, gone once the diff is
# written; the project's GitHub token reads it through GitRunner, as the
# shallow clones of Designs::AppRepos do. Lock files are left out of the
# diff, and a diff past MAX_BYTES is cut.
class Designs::AppChanges
  MAX_BYTES = 400_000
  EXCLUDED = %w[:(exclude)*.lock :(exclude)package-lock.json :(exclude)yarn.lock :(exclude)pnpm-lock.yaml].freeze

  def initialize(setup)
    @setup = setup
    @project = setup.project
    @since = setup.since_setup
  end

  # [{ "repo", "branch", "from", "to", "path" }]: path is nil for a
  # repository nothing changed in. The setup's app_commits become the commits
  # read now, for the next import to start from.
  def fetch!
    FileUtils.mkdir_p(changes_dir)
    rows = Designs::AppRepos.new(@setup).repos.each_with_index.map do |(_role, name, branch), index|
      read(name, branch, index)
    end
    @setup.update!(app_commits: rows.map { |row| { "repo" => row["repo"], "branch" => row["branch"], "sha" => row["to"] } })
    rows
  end

  private

  def changes_dir = @setup.run_dir.join("changes")

  def read(name, branch, index)
    history = @setup.run_dir.join("history", "#{index + 1}-#{name.parameterize}.git")
    FileUtils.rm_rf(history)
    FileUtils.mkdir_p(history.dirname)
    GitRunner.run!("clone", "--quiet", "--bare", "--filter=blob:none", "--", Designs::AppRepos.url_for.call(name), history.to_s,
                   chdir: history.dirname.to_s, token: token)
    head = branch ? "refs/heads/#{branch}" : "HEAD"
    to = git(history, "rev-parse", head).strip
    from = baseline(history, name, branch, head)
    path = (write_diff(history, name, branch, from, to, index) if from && from != to)
    { "repo" => name, "branch" => branch, "from" => from, "to" => to, "path" => path&.to_s }
  ensure
    FileUtils.rm_rf(history) if history
  end

  # The commit the earlier import read, else the branch's commit as that
  # import started.
  def baseline(history, name, branch, head)
    recorded = Array(@since&.app_commits).find { |row| row["repo"] == name && row["branch"] == branch && row["sha"].present? }
    return recorded["sha"] if recorded && commit?(history, recorded["sha"])

    since = @since&.created_at or return
    git(history, "rev-list", "-1", "--before=#{since.iso8601}", head).strip.presence
  end

  def commit?(history, sha)
    git(history, "cat-file", "-e", "#{sha}^{commit}")
    true
  rescue GitRunner::Error
    false
  end

  def write_diff(history, name, branch, from, to, index)
    stat = git(history, "diff", "--stat=200", from, to, "--", ".", *EXCLUDED)
    diff = git(history, "diff", "--no-color", "--no-ext-diff", from, to, "--", ".", *EXCLUDED)
    diff = "#{diff.byteslice(0, MAX_BYTES).scrub}\n… (cut here: the diff goes on)\n" if diff.bytesize > MAX_BYTES
    file = changes_dir.join("#{index + 1}-#{name.parameterize}.diff")
    File.chmod(0o644, file) if file.exist?
    File.write(file, "# #{name}#{" @ #{branch}" if branch}: #{from.first(7)}..#{to.first(7)}\n\n#{stat}\n#{diff}")
    File.chmod(0o444, file)
    file
  end

  def git(history, *args)
    GitRunner.run!(*args, chdir: history.to_s)
  end

  def token = ProjectCredentials.new(@project).github_token
end
