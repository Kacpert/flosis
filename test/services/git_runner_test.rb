require "test_helper"

class GitRunnerTest < ActiveSupport::TestCase
  setup { @dir = Dir.mktmpdir("git-runner") }
  teardown { FileUtils.remove_entry(@dir) }

  test "returns git's output" do
    assert_match(/\Agit version /, GitRunner.run!("--version", chdir: @dir))
  end

  test "a failing command raises with git's message and without the token" do
    error = assert_raises(GitRunner::Error) do
      GitRunner.run!("not-a-command-ghp_SECRET123", chdir: @dir, token: "ghp_SECRET123")
    end
    assert_match(/not a git command/, error.message)
    assert_not_includes error.message, "ghp_SECRET123"
  end

  test "the token travels in the environment, never in the arguments" do
    env = GitRunner.env("ghp_SECRET123")
    assert_equal "ghp_SECRET123", env["FLOSIS_GIT_TOKEN"]
    assert_equal "0", env["GIT_TERMINAL_PROMPT"]
    assert_equal "C", env["LC_ALL"]
    assert File.executable?(env["GIT_ASKPASS"])
  end

  test "the askpass script answers the username and the password prompts" do
    env = GitRunner.env("ghp_SECRET123")
    user, = Open3.capture2(env, env["GIT_ASKPASS"], "Username for 'https://github.com': ")
    pass, = Open3.capture2(env, env["GIT_ASKPASS"], "Password for 'https://x-access-token@github.com': ")
    assert_equal "x-access-token", user.chomp
    assert_equal "ghp_SECRET123", pass.chomp
  end

  test "github_url carries no credentials" do
    assert_equal "https://github.com/acme/designs.git", GitRunner.github_url("acme/designs")
  end
end
