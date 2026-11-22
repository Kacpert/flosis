# What changed in the app since an import (Designs imports): for each app
# repository the setup form names, the range from the commit the earlier
# import read it at to the one it is at now, read from the app's history
# (Designs::AppHistory). Since 2026-11-22 the turn reads the changes itself,
# with the git tool, as far as it needs: a diff written into a file and cut at
# 400 KB had left most of a big change unread (import 3, Nov 22). An import
# that recorded no commits (the first ones did not) is taken at the commit its
# branch had when that import started. A repository the earlier import did
# not read, while it read others, is new to the designs: it has no range, and
# the turn reads it whole.
class Designs::AppChanges
  EXCLUDED = %w[:(exclude)*.lock :(exclude)package-lock.json :(exclude)yarn.lock :(exclude)pnpm-lock.yaml].freeze
  # The --stat the turn's message gives, at most this many files.
  STAT_FILES = 300

  def initialize(setup)
    @setup = setup
    @project = setup.project
    @since = setup.since_setup
  end

  # [{ "repo", "branch", "from", "to", "commits", "stat", "new" }]: from is
  # nil for a repository new to the designs (new: true); stat is nil when
  # nothing changed. The setup's app_commits become the commits read now, for
  # the next import to start from.
  def fetch!
    history = Designs::AppHistory.new(@project)
    rows = history.fetch!(@setup).map { |row| read(history, row) }
    @setup.update!(app_commits: rows.map { |row| { "repo" => row["repo"], "branch" => row["branch"], "sha" => row["to"] } })
    rows
  end

  private

  def read(history, row)
    to = row["sha"]
    return row.slice("repo", "branch").merge("from" => nil, "to" => to, "commits" => nil, "stat" => nil, "new" => true) if new_repo?(row)

    from = baseline(history, row)
    changed = from && from != to
    row.slice("repo", "branch").merge(
      "from" => from, "to" => to, "new" => false,
      "commits" => (changed ? history.git(row["repo"], "rev-list", "--count", "#{from}..#{to}").strip.to_i : 0),
      "stat" => (history.git(row["repo"], "diff", "--stat=160", "--stat-count=#{STAT_FILES}", from, to, "--", ".", *EXCLUDED).strip.presence if changed)
    )
  end

  # The earlier import read other repositories, but not this one.
  def new_repo?(row)
    recorded = Array(@since&.app_commits).select { |commit| commit["sha"].present? }
    recorded.any? && recorded.none? { |commit| commit["repo"] == row["repo"] }
  end

  # The commit the earlier import read, else the branch's commit as that
  # import started.
  def baseline(history, row)
    recorded = Array(@since&.app_commits).find { |commit| commit["repo"] == row["repo"] && commit["branch"] == row["branch"] && commit["sha"].present? }
    return recorded["sha"] if recorded && commit?(history, row["repo"], recorded["sha"])

    since = @since&.created_at or return
    history.git(row["repo"], "rev-list", "-1", "--before=#{since.iso8601}", row["branch"] ? "refs/heads/#{row['branch']}" : "HEAD").strip.presence
  end

  def commit?(history, repo, sha)
    history.git(repo, "cat-file", "-e", "#{sha}^{commit}")
    true
  rescue GitRunner::Error
    false
  end
end
