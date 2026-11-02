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

  # A hung git holds the design repo's lock, and its job a worker thread, for
  # as long as it hangs: a transfer that stalls must fail instead.
  test "a transfer slower than 1000 bytes a second for a minute gives up" do
    [ nil, "ghp_SECRET123" ].each do |token|
      env = GitRunner.env(token)
      assert_equal "1000", env["GIT_HTTP_LOW_SPEED_LIMIT"], token.inspect
      assert_equal "60", env["GIT_HTTP_LOW_SPEED_TIME"], token.inspect
    end
  end

  # Every remote in the other tests is a folder, which asks for no credentials,
  # so this is where git is seen to take the token from askpass. The repo's own
  # helper stands in for a machine-wide one (osxkeychain on a laptop), which the
  # empty credential.helper must silence. The machine's real git config is kept
  # out, so no real helper could answer even if that reset broke, and nothing
  # git prints is shown when an assertion fails.
  test "git takes the token from askpass, and no credential helper is asked" do
    without_machine_git_config do
      system("git", "init", "--quiet", @dir, exception: true)
      system("git", "-C", @dir, "config", "credential.helper", "!f() { echo password=from-helper; }; f", exception: true)

      output = GitRunner.run!("-c", %q(alias.fill=!printf 'protocol=https\nhost=github.com\n\n' | git credential fill),
                              "fill", chdir: @dir, token: "tok-123")

      assert output.include?("password=tok-123"), "askpass did not answer with the token"
      assert_not output.include?("from-helper"), "a credential helper answered"
    end
  end

  private

  def without_machine_git_config
    saved = ENV.to_h.slice("GIT_CONFIG_GLOBAL", "GIT_CONFIG_NOSYSTEM")
    ENV["GIT_CONFIG_GLOBAL"] = File::NULL
    ENV["GIT_CONFIG_NOSYSTEM"] = "1"
    yield
  ensure
    %w[GIT_CONFIG_GLOBAL GIT_CONFIG_NOSYSTEM].each { |name| saved.key?(name) ? ENV[name] = saved[name] : ENV.delete(name) }
  end
end
