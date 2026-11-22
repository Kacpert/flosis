require "test_helper"

# The app's history for an import's turns (Kacper, 2026-11-22: "dobrze żeby
# miał po prostu dostęp do gita"): a bare, full clone of each app repository,
# kept between imports and fetched at the start of each. Local bare
# repositories stand in for GitHub.
class Designs::AppHistoryTest < ActiveSupport::TestCase
  setup do
    @dir = Dir.mktmpdir("app-history")
    @project = projects(:jira_project)
    @project.update!(workspace_dir: File.join(@dir, "workspace"), design_app_repos: [ { "role" => "Frontend", "repo" => "acme/app" } ])
    @work = File.join(@dir, "app-work")
    @remote = File.join(@dir, "app.git")
    system("git", "init", "--quiet", "-b", "main", @work, exception: true)
    commit("a.txt" => "one\n")
    @second = commit("a.txt" => "two\n")
    system("git", "clone", "--quiet", "--bare", @work, @remote, exception: true)
    Designs::AppRepos.url_for = ->(_name) { @remote }
  end

  teardown do
    Designs::AppRepos.url_for = nil
    FileUtils.chmod_R("u+w", @dir)
    FileUtils.remove_entry(@dir)
  end

  def commit(files)
    files.each { |path, body| File.write(File.join(@work, path), body) }
    system("git", "-C", @work, "add", ".", exception: true)
    system("git", "-C", @work, "-c", "user.email=t@example.test", "-c", "user.name=T", "commit", "--quiet", "-m", "change", exception: true)
    IO.popen([ "git", "-C", @work, "rev-parse", "HEAD" ], &:read).strip
  end

  test "fetch! clones each app repository bare and full, then fetches it" do
    history = Designs::AppHistory.new(@project)

    assert_equal [ [ "acme/app", nil, @second ] ], history.fetch!.map { |row| row.values_at("repo", "branch", "sha") }
    path = history.path("acme/app")
    assert path.join("HEAD").file?
    assert_equal "2", IO.popen([ "git", "--git-dir", path.to_s, "rev-list", "--count", "HEAD" ], &:read).strip

    third = commit("a.txt" => "three\n")
    system("git", "-C", @work, "push", "--quiet", @remote, "main", exception: true)
    assert_equal third, history.fetch!.first["sha"]
  end

  test "clones lists the clones that exist" do
    history = Designs::AppHistory.new(@project)
    assert_equal({}, history.clones)

    history.fetch!
    assert_equal({ "acme/app" => history.path("acme/app").to_s }, history.clones)
  end

  test "a repository that cannot be read is a note, not a stop" do
    @project.update!(design_app_repos: [ { "role" => "Frontend", "repo" => "acme/app" }, { "role" => "Backend", "repo" => "acme/missing" } ])
    Designs::AppRepos.url_for = ->(name) { name == "acme/missing" ? File.join(@dir, "missing.git") : @remote }
    setup = @project.design_setups.create!(kind: "resync", status: "active", phase: "resync", started_by: users(:one))

    assert_equal [ "acme/app" ], Designs::AppHistory.new(@project).fetch!(setup).map { |row| row["repo"] }
    assert_match %r{acme/missing}, setup.reload.notes.last["text"]
  end
end
