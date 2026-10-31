require "open3"

# Crawls a project's running app as each of its setup roles (the Node and
# Playwright script in lib/designs_crawler), for a setup run to read: one
# folder per crawl under the project's designs folder (Ruling P5-R3),
# designs_dir/design-crawls/<UTC timestamp>/, with a screenshot and the DOM of
# every page and a crawl.json summary.
#
# Role passwords reach the crawler on its stdin only: never in its argv or
# environment, which other users of the host can read, and never in a log.
# Anything the crawler says on failure is scrubbed of them before it is kept
# (Ruling P5-R5). A finished bundle is sealed read-only (Ruling P5-R1): turns
# read it, and nothing writes to it again.
class Designs::CrawlJob < ApplicationJob
  queue_as :designs

  TIMEOUT = 20.minutes
  MAX_PAGES_PER_ROLE = 40
  # How long a crawler that outlived its time gets to stop after TERM.
  KILL_GRACE = 5.seconds

  class << self
    # Test seam: what runs the crawler. Called with argv:, env:, stdin: and
    # out_dir:; returns [stdout, stderr, exit status]. Set to nil, it is the
    # real one again.
    attr_writer :runner

    def runner
      @runner || method(:run_node)
    end

    # The crawler's folder, where its node_modules live: the script runs from
    # there, since Node resolves an import from the script's own folder.
    def crawler_dir
      ENV["DESIGNS_CRAWLER_DIR"].presence || Rails.root.join("lib/designs_crawler").to_s
    end

    def run_node(argv:, env:, stdin:, out_dir:)
      Open3.popen3(env, *argv, chdir: crawler_dir) do |input, output, errors, waiter|
        input.write(stdin)
        input.close
        out = Thread.new { output.read }
        err = Thread.new { errors.read }
        unless waiter.join(TIMEOUT)
          stop(waiter.pid)
          return [ out.value, "The crawl took longer than #{TIMEOUT.inspect} and was stopped.", 124 ]
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

  def perform(design_setup_id)
    setup = DesignSetup.find_by(id: design_setup_id)
    return unless setup

    crawl(setup)
  rescue StandardError => e
    Rails.logger.error("[#{self.class.name}] setup #{design_setup_id}: #{e.class}")
    setup&.update!(crawl_error: scrub("The crawl could not run: #{e.message}", setup).truncate(1_000))
  end

  private

  def crawl(setup)
    project = setup.project
    out_dir = Pathname(project.designs_dir).join("design-crawls", Time.now.utc.strftime("%Y%m%dT%H%M%SZ"))
    FileUtils.mkdir_p(out_dir)
    argv = [ "node", File.join(self.class.crawler_dir, "crawl.mjs"), out_dir.to_s ]
    _, errors, status = self.class.runner.call(argv: argv, env: crawler_env, stdin: input(project).to_json, out_dir: out_dir.to_s)
    summary = read_summary(out_dir)

    if status.to_i.zero? && summary
      seal(out_dir)
      setup.update!(crawl_dir: out_dir.to_s, crawled_at: Time.current, crawl_error: nil)
      note(project, report(summary))
    else
      error = errors.to_s.strip.presence || "The crawl failed (exit #{status})."
      setup.update!(crawl_error: scrub(error, setup).truncate(1_000))
    end
  end

  def input(project)
    {
      baseUrl: project.design_app_url,
      maxPagesPerRole: MAX_PAGES_PER_ROLE,
      roles: project.design_setup_roles.map do |role|
        { name: role.name, loginUrl: role.login_url, username: role.username, password: role.password, notes: role.notes }
      end
    }
  end

  # Where Playwright keeps its browser, when the host says; nothing secret.
  def crawler_env
    ENV.slice("PLAYWRIGHT_BROWSERS_PATH", "TMPDIR")
  end

  def read_summary(out_dir)
    data = JSON.parse(out_dir.join("crawl.json").read)
    data.is_a?(Hash) && data["roles"].is_a?(Array) ? data : nil
  rescue JSON::ParserError, SystemCallError
    nil
  end

  def seal(dir)
    Find.find(dir.to_s) do |path|
      next if File.symlink?(path)

      File.chmod(File.directory?(path) ? 0o555 : 0o444, path)
    end
  end

  def report(summary)
    roles = summary["roles"].grep(Hash)
    crawled = roles.select { |role| role["ok"] }
    failed = roles.reject { |role| role["ok"] }
    pages = crawled.sum { |role| Array(role["pages"]).size }
    text = "Crawled #{pages} #{"page".pluralize(pages)} as #{crawled.map { |role| role["name"] }.join(", ")}."
    failed.each { |role| text += " #{role["name"]} could not be crawled: #{role["error"].presence || "no reason given"}." }
    text
  end

  def note(project, text)
    ChatSession.active.where(project: project, purpose: "designs_setup").order(created_at: :desc).first
               &.chat_messages&.create!(role: "assistant", kind: "system", content: text)
  end

  def scrub(text, setup)
    setup.project.design_setup_roles.map(&:password).compact_blank.uniq
         .reduce(text.to_s) { |scrubbed, password| scrubbed.gsub(password, "[password]") }
  end
end
