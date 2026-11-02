require "test_helper"

# The setup reads the app's repositories (the Designs setup, feature by
# feature): each one the form names, at the branch it names, cloned into the
# run's folder and left read-only. Local bare repositories stand in for GitHub.
class Designs::AppReposTest < ActiveSupport::TestCase
  setup do
    @dir = Dir.mktmpdir("app-repos")
    @project = projects(:jira_project)
    @project.update!(workspace_dir: File.join(@dir, "workspace"))
    @setup = DesignSetup.create!(project: @project, started_by: users(:one))
    @remotes = { "acme/app" => bare_repo("app", "main" => "main\n", "production" => "production\n") }
    Designs::AppRepos.url_for = ->(name) { @remotes.fetch(name) { File.join(@dir, "nowhere.git") } }
  end

  teardown do
    Designs::AppRepos.url_for = nil
    FileUtils.chmod_R("u+w", @dir)
    FileUtils.remove_entry(@dir)
  end

  # A bare repository with one commit per branch, each holding BRANCH.txt.
  def bare_repo(name, branches)
    remote = File.join(@dir, "#{name}.git")
    work = File.join(@dir, "#{name}-work")
    system("git", "init", "--quiet", "-b", branches.keys.first, work, exception: true)
    branches.each_with_index do |(branch, body), index|
      system("git", "-C", work, "checkout", "--quiet", "-b", branch, exception: true) unless index.zero?
      File.write(File.join(work, "BRANCH.txt"), body)
      system("git", "-C", work, "add", ".", exception: true)
      system("git", "-C", work, "-c", "user.email=t@example.test", "-c", "user.name=T", "commit", "--quiet", "-m", branch, exception: true)
    end
    system("git", "clone", "--quiet", "--bare", work, remote, exception: true)
    system("git", "-C", remote, "symbolic-ref", "HEAD", "refs/heads/#{branches.keys.first}", exception: true)
    remote
  end

  def repos(*rows) = @project.update!(design_app_repos: rows.map { |repo| { "role" => "Frontend", "repo" => repo } })

  test "each repository is cloned at its branch and left read-only" do
    repos("acme/app@production")
    fetched = Designs::AppRepos.new(@setup).fetch!

    assert_equal [ [ "Frontend", "acme/app", "production" ] ], fetched.map { |row| row.values_at("role", "repo", "branch") }
    dir = Pathname(fetched.first["dir"])
    assert_equal @setup.run_dir.join("apps", "1-acme-app"), dir
    assert_equal "production\n", dir.join("BRANCH.txt").read
    assert_equal 0o444, dir.join("BRANCH.txt").stat.mode & 0o777
    assert_equal 0o555, dir.stat.mode & 0o777
    assert_equal [ dir.to_s ], Designs::AppRepos.new(@setup).dirs
  end

  test "a repository named without a branch is read at its default one" do
    repos("acme/app")
    fetched = Designs::AppRepos.new(@setup).fetch!
    assert_nil fetched.first["branch"]
    assert_equal "main\n", Pathname(fetched.first["dir"]).join("BRANCH.txt").read
  end

  test "a repository that cannot be read is a note, and the others are read" do
    repos("acme/gone", "acme/app@production")
    fetched = Designs::AppRepos.new(@setup).fetch!

    assert_equal [ "acme/app" ], fetched.map { |row| row["repo"] }
    assert_equal [ "Reading the repositories" ], @setup.reload.notes.map { |note| note["label"] }
    assert_match(/acme\/gone could not be read/, @setup.notes.first["text"])
  end

  test "a run whose repositories all fail stops" do
    repos("acme/gone")
    error = assert_raises(Designs::AppRepos::Failure) { Designs::AppRepos.new(@setup).fetch! }
    assert_match(/No app repository could be read/, error.message)
  end

  test "reading again replaces what an earlier attempt left" do
    repos("acme/app@production")
    Designs::AppRepos.new(@setup).fetch!
    fetched = Designs::AppRepos.new(@setup).fetch!
    assert_equal "production\n", Pathname(fetched.first["dir"]).join("BRANCH.txt").read
  end
end
