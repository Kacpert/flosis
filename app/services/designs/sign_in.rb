require "open3"

# Signing in to a setup run's test environment as each of its contexts (the
# Designs setup, feature by feature), with lib/designs_crawler/sign_in.mjs. It
# leaves each context's browser state (its cookies and storage) in
# run_dir/auth/<slug>.json, for the setup's browser to start from, so that no
# password ever reaches the browser or Claude.
#
# Passwords reach the script on its stdin only: never in its argv or
# environment, which other users of the host can read, and never in a log;
# what it says on failure is scrubbed of them. The states are 0600 in a 0700
# folder. A context that cannot sign in is a note on the run, and its old
# state goes; a run nobody can sign in to stops. Every feature signs in
# afresh: a session may not last a run of many hours.
class Designs::SignIn
  class Failure < StandardError; end

  TIMEOUT = 5.minutes
  # How long a sign-in that outlived its time gets to stop after TERM.
  KILL_GRACE = 5.seconds
  MASK = "••••••".freeze

  class << self
    # Test seam: what runs the sign-in. Called with argv:, env: and stdin:;
    # returns [stdout, stderr, exit status]. Set to nil, it is the real one.
    attr_writer :runner

    def runner
      @runner || method(:run_node)
    end

    # The tools' folder, where their node_modules live: the script runs from
    # there, since Node resolves an import from the script's own folder.
    def crawler_dir
      ENV["DESIGNS_CRAWLER_DIR"].presence || Rails.root.join("lib/designs_crawler").to_s
    end

    # What the Node tools run with, and nothing more of the app's environment:
    # where Playwright keeps Chromium, the temp folder, and the libraries
    # headless Chromium needs that the host lacks (Hostido has no libasound,
    # libatk-bridge, libatspi, libgbm or libwayland-server), from the folder
    # DESIGNS_BROWSER_LIBS names. Only the browser's processes get them.
    def node_env
      env = ENV.slice("PLAYWRIGHT_BROWSERS_PATH", "TMPDIR")
      env["LD_LIBRARY_PATH"] = ENV["DESIGNS_BROWSER_LIBS"] if ENV["DESIGNS_BROWSER_LIBS"].present?
      env
    end

    # What the browser knows a context by: "2-hiring-manager".
    def slug(role)
      "#{role.position.to_i + 1}-#{role.name.to_s.parameterize.presence || 'context'}"
    end

    def run_node(argv:, env:, stdin:)
      Open3.popen3(env, *argv, chdir: crawler_dir) do |input, output, errors, waiter|
        input.write(stdin)
        input.close
        out = Thread.new { output.read }
        err = Thread.new { errors.read }
        unless waiter.join(TIMEOUT)
          stop(waiter.pid)
          return [ out.value, "The sign-in took longer than #{TIMEOUT.inspect} and was stopped.", 124 ]
        end
        [ out.value, err.value, waiter.value.exitstatus ]
      end
    end

    private

    def stop(pid)
      Process.kill("TERM", pid)
      sleep KILL_GRACE
      Process.kill("KILL", pid)
    rescue Errno::ESRCH
      nil # gone already
    end
  end

  def initialize(setup)
    @setup = setup
    @project = setup.project
  end

  # Signs in as every context and returns { slug => signed in? }.
  def call
    roles = @project.design_setup_roles.to_a
    raise Failure, "The setup has no context to sign in as." if roles.empty?

    prepare
    out, errors, status = self.class.runner.call(argv: [ "node", File.join(self.class.crawler_dir, "sign_in.mjs"), auth.to_s ],
                                                 env: self.class.node_env, stdin: input(roles).to_json)
    results = parse(out)
    raise Failure, scrub("The sign-in could not run: #{errors.to_s.strip.presence || "exit #{status}"}") unless results

    auth.glob("*.json").each { |file| File.chmod(0o600, file) }
    names = roles.to_h { |role| [ self.class.slug(role), role.name ] }
    failures = results.reject { |row| row["ok"] }.map do |row|
      FileUtils.rm_f(auth.join("#{row['slug']}.json"))
      message = scrub(row["error"].to_s.presence || "it did not say why").delete_suffix(".")
      @setup.note!("Signing in", "#{names.fetch(row['slug'], row['slug'])} could not sign in: #{message}.")
      message
    end
    raise Failure, "No context could sign in to the test environment: #{failures.uniq.join('; ')}." if results.none? { |row| row["ok"] }

    results.to_h { |row| [ row["slug"], row["ok"] == true ] }
  end

  private

  def auth = @setup.run_dir.join("auth")

  def prepare
    FileUtils.mkdir_p(auth)
    [ @setup.run_dir, auth ].each { |dir| File.chmod(0o700, dir) }
  end

  def input(roles)
    { roles: roles.map { |role| { slug: self.class.slug(role), name: role.name, loginUrl: role.login_url, username: role.username, password: role.password } } }
  end

  def parse(out)
    data = JSON.parse(out.to_s)
    data["roles"] if data.is_a?(Hash) && data["roles"].is_a?(Array)
  rescue JSON::ParserError
    nil
  end

  def scrub(text)
    @project.design_setup_roles.map(&:password).compact_blank.reduce(text.to_s) { |out, secret| out.gsub(secret, MASK) }.truncate(1_000)
  end
end
