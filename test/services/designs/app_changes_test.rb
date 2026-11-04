require "test_helper"

# What changed in the app since an import (Designs imports): each app
# repository's diff from the commit that import read to the one read now,
# written where the resync's turns can read it. Local bare repositories stand
# in for GitHub.
class Designs::AppChangesTest < ActiveSupport::TestCase
  setup do
    @dir = Dir.mktmpdir("app-changes")
    @project = projects(:jira_project)
    @project.update!(workspace_dir: File.join(@dir, "workspace"), design_app_repos: [ { "role" => "Frontend", "repo" => "acme/app" } ])
    @work = File.join(@dir, "app-work")
    @remote = File.join(@dir, "app.git")
    system("git", "init", "--quiet", "-b", "main", @work, exception: true)
    @first = commit({ "app/views/bugs/index.html.erb" => "<h1>Bugs</h1>\n" }, at: "2026-11-02T12:00:00+01:00")
    system("git", "clone", "--quiet", "--bare", @work, @remote, exception: true)
    Designs::AppRepos.url_for = ->(_name) { @remote }
  end

  teardown do
    Designs::AppRepos.url_for = nil
    FileUtils.chmod_R("u+w", @dir)
    FileUtils.remove_entry(@dir)
  end

  def commit(files, at:)
    files.each do |path, body|
      FileUtils.mkdir_p(File.dirname(File.join(@work, path)))
      File.write(File.join(@work, path), body)
    end
    env = { "GIT_AUTHOR_DATE" => at, "GIT_COMMITTER_DATE" => at }
    system("git", "-C", @work, "add", ".", exception: true)
    system(env, "git", "-C", @work, "-c", "user.email=t@example.test", "-c", "user.name=T", "commit", "--quiet", "-m", "change", exception: true)
    IO.popen([ "git", "-C", @work, "rev-parse", "HEAD" ], &:read).strip
  end

  def push = system("git", "-C", @work, "push", "--quiet", @remote, "main", exception: true)

  def resync_from(since)
    @project.design_setups.create!(kind: "resync", since_setup: since, status: "active", phase: "resync", started_by: users(:one))
  end

  test "the changes since the last import are written for the AI" do
    since = @project.design_setups.create!(status: "approved", started_by: users(:one), app_commits: [ { "repo" => "acme/app", "branch" => nil, "sha" => @first } ])
    latest = commit({ "app/views/bugs/index.html.erb" => "<h1>Bugs</h1>\n<form class=\"filter\"></form>\n" }, at: "2026-11-05T12:00:00+01:00")
    push
    resync = resync_from(since)

    changes = Designs::AppChanges.new(resync).fetch!
    assert_equal [ [ "acme/app", @first, latest ] ], changes.map { |row| row.values_at("repo", "from", "to") }
    diff = Pathname(changes.first["path"]).read
    assert_includes diff, "app/views/bugs/index.html.erb"
    assert_includes diff, "+<form class=\"filter\"></form>"
    assert_equal resync.run_dir.join("changes"), Pathname(changes.first["path"]).dirname
    assert_equal [ { "repo" => "acme/app", "branch" => nil, "sha" => latest } ], resync.reload.app_commits
  end

  test "an import that recorded no commits is taken at the time it read the repositories" do
    second = commit({ "app/views/bugs/index.html.erb" => "<h1>Bugs</h1>\n<p>Trend</p>\n" }, at: "2026-11-03T00:30:00+01:00")
    commit({ "app/views/bugs/index.html.erb" => "<h1>Bugs</h1>\n<p>Trend</p>\n<p>Filter</p>\n" }, at: "2026-11-04T12:00:00+01:00")
    push
    since = @project.design_setups.create!(status: "approved", started_by: users(:one), created_at: Time.zone.parse("2026-11-03T01:40:00+01:00"))

    changes = Designs::AppChanges.new(resync_from(since)).fetch!
    assert_equal second, changes.first["from"]
    assert_includes Pathname(changes.first["path"]).read, "+<p>Filter</p>"
  end

  # Final review C3: a blobless clone fetches each file it diffs from GitHub,
  # so every git it runs carries the project's token, and the diff works on a
  # real partial clone.
  test "a private repository's history is read with the project's token, file contents and all" do
    system("git", "-C", @remote, "config", "uploadpack.allowFilter", "true", exception: true)
    Designs::AppRepos.url_for = ->(_name) { "file://#{@remote}" }
    @project.update!(github_token: "ghp_private")
    since = @project.design_setups.create!(status: "approved", started_by: users(:one), app_commits: [ { "repo" => "acme/app", "branch" => nil, "sha" => @first } ])
    commit({ "app/views/bugs/index.html.erb" => "<h1>Bugs</h1>\n<p>Trend</p>\n" }, at: "2026-11-05T12:00:00+01:00")
    push
    tokens = []
    run = GitRunner.method(:run!)
    GitRunner.define_singleton_method(:run!) { |*args, chdir:, token: nil| tokens << [ args.first, token ]; run.call(*args, chdir: chdir, token: token) }
    begin
      changes = Designs::AppChanges.new(resync_from(since)).fetch!
    ensure
      GitRunner.define_singleton_method(:run!, run)
    end

    assert_includes Pathname(changes.first["path"]).read, "+<p>Trend</p>"
    assert_equal [ "ghp_private" ], tokens.map(&:last).uniq, "every git run took the token: #{tokens.inspect}"
  end

  test "a repository nothing changed in has no diff" do
    since = @project.design_setups.create!(status: "approved", started_by: users(:one), app_commits: [ { "repo" => "acme/app", "branch" => nil, "sha" => @first } ])
    changes = Designs::AppChanges.new(resync_from(since)).fetch!
    assert_equal [ [ @first, @first, nil ] ], changes.map { |row| row.values_at("from", "to", "path") }
  end
end
