require "test_helper"

# The setup signs in to the test environment as each context (the Designs
# setup, feature by feature), with the Node sign-in stood in for: passwords
# reach it on stdin only, the states it leaves are private, and a context that
# cannot sign in is a note unless none can.
class Designs::SignInTest < ActiveSupport::TestCase
  setup do
    @dir = Dir.mktmpdir("sign-in")
    @project = projects(:jira_project)
    @project.update!(workspace_dir: File.join(@dir, "workspace"))
    @project.design_setup_roles.create!(name: "Admin", login_url: "https://s.test/login", username: "admin@s.test", password: "admin-secret", position: 0)
    @project.design_setup_roles.create!(name: "Hiring manager", login_url: "https://s.test/login", username: "hm@s.test", password: "hm-secret", position: 1)
    @setup = DesignSetup.create!(project: @project, started_by: users(:one))
    @calls = []
    Designs::SignIn.pause = 0
  end

  teardown do
    Designs::SignIn.runner = nil
    Designs::SignIn.pause = nil
    FileUtils.remove_entry(@dir)
  end

  # The sign-in as sign_in.mjs leaves it: a state for each context that signs
  # in, and what it prints.
  def runner(ok: %w[1-admin 2-hiring-manager])
    lambda do |argv:, env:, stdin:|
      @calls << { argv: argv, env: env, stdin: stdin }
      out = Pathname(argv.last)
      roles = JSON.parse(stdin)["roles"].map do |role|
        next { "slug" => role["slug"], "ok" => false, "error" => "login failed (still on the login page)" } unless ok.include?(role["slug"])

        out.join("#{role['slug']}.json").write("{}")
        { "slug" => role["slug"], "ok" => true }
      end
      [ { roles: roles }.to_json, "", roles.any? { |role| role["ok"] } ? 0 : 2 ]
    end
  end

  test "passwords reach the sign-in on stdin only" do
    Designs::SignIn.runner = runner
    Designs::SignIn.new(@setup).call

    call = @calls.sole
    assert_equal [ "node", File.join(Designs::SignIn.crawler_dir, "sign_in.mjs"), @setup.run_dir.join("auth").to_s ], call[:argv]
    assert_empty (call[:argv] + call[:env].values).grep(/secret/)
    assert_empty call[:env].keys - %w[PLAYWRIGHT_BROWSERS_PATH TMPDIR]
    roles = JSON.parse(call[:stdin])["roles"]
    assert_equal [ %w[1-admin Admin admin@s.test admin-secret], %w[2-hiring-manager Hiring\ manager hm@s.test hm-secret] ],
                 roles.map { |role| role.values_at("slug", "name", "username", "password") }
  end

  # Hostido lacks libraries headless Chromium needs; they live in a folder of
  # our own, named in DESIGNS_BROWSER_LIBS, and reach the browser alone.
  test "the browser's own libraries reach the sign-in, and nothing else of the app" do
    Designs::SignIn.runner = runner
    with_env("DESIGNS_BROWSER_LIBS" => "/home/flosis/browser-libs") { Designs::SignIn.new(@setup).call }
    assert_equal "/home/flosis/browser-libs", @calls.sole[:env]["LD_LIBRARY_PATH"]
    assert_equal({ "LD_LIBRARY_PATH" => "/x" }, with_env("DESIGNS_BROWSER_LIBS" => "/x") { Designs::SignIn.node_env.slice("LD_LIBRARY_PATH") })
    assert_not with_env("DESIGNS_BROWSER_LIBS" => nil) { Designs::SignIn.node_env.key?("LD_LIBRARY_PATH") }
  end

  test "the states are private, and each context's is known by its slug" do
    Designs::SignIn.runner = runner
    result = Designs::SignIn.new(@setup).call

    assert_equal({ "1-admin" => true, "2-hiring-manager" => true }, result)
    assert_equal 0o700, @setup.run_dir.join("auth").stat.mode & 0o777
    assert_equal 0o600, @setup.run_dir.join("auth", "1-admin.json").stat.mode & 0o777
    assert_equal "2-hiring-manager", Designs::SignIn.slug(@project.design_setup_roles.second)
  end

  test "a context that cannot sign in is a note, once" do
    Designs::SignIn.runner = runner(ok: %w[1-admin])
    2.times { Designs::SignIn.new(@setup).call }

    assert_equal [ { "label" => "Signing in", "text" => "Hiring manager could not sign in: login failed (still on the login page)." } ], @setup.reload.notes
    assert_not @setup.run_dir.join("auth", "2-hiring-manager.json").exist?
  end

  # The test environment may be down for a minute (a deploy of it): a
  # sign-in nobody passes is tried again before it stops the run.
  test "a sign-in nobody passes is tried again, and goes on once it works" do
    attempts = 0
    failing = runner(ok: [])
    working = runner
    Designs::SignIn.runner = ->(**args) { (attempts += 1) < 3 ? failing.call(**args) : working.call(**args) }
    assert_equal({ "1-admin" => true, "2-hiring-manager" => true }, Designs::SignIn.new(@setup).call)
    assert_equal 3, attempts
  end

  test "a run nobody can sign in to stops, with the reason" do
    Designs::SignIn.runner = runner(ok: [])
    error = assert_raises(Designs::SignIn::Failure) { Designs::SignIn.new(@setup).call }
    assert_equal Designs::SignIn::ATTEMPTS, @calls.size
    assert_match(/No context could sign in to the test environment/, error.message)
    assert_match(/login failed/, error.message)
  end

  test "a sign-in that breaks stops the run without the passwords" do
    Designs::SignIn.runner = ->(**) { [ "", "Error: admin-secret was refused", 1 ] }
    error = assert_raises(Designs::SignIn::Failure) { Designs::SignIn.new(@setup).call }
    assert_no_match(/admin-secret/, error.message)
  end

  test "a state an earlier sign-in left for a context that now fails is removed" do
    Designs::SignIn.runner = runner
    Designs::SignIn.new(@setup).call
    Designs::SignIn.runner = runner(ok: %w[1-admin])
    Designs::SignIn.new(@setup).call
    assert_not @setup.run_dir.join("auth", "2-hiring-manager.json").exist?
  end
end
