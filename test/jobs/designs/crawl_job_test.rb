require "test_helper"

class Designs::CrawlJobTest < ActiveJob::TestCase
  setup do
    @project = projects(:jira_project)
    @dir = Dir.mktmpdir("crawl")
    @project.update!(workspace_dir: @dir, design_app_url: "https://app.test")
    @project.design_setup_roles.create!(name: "Admin", login_url: "https://app.test/login", username: "a", password: "s3cret-pass")
    @setup = DesignSetup.create!(project: @project, started_by: users(:one), crawl_requested_at: Time.current)
  end

  teardown do
    Designs::CrawlJob.runner = nil
    # The bundle is sealed read-only (Ruling P5-R1).
    FileUtils.chmod_R("u+w", @dir)
    FileUtils.remove_entry(@dir)
  end

  def setup_chat
    ChatSession.create!(project: @project, workspace: @project.workspace, user: users(:one), purpose: "designs_setup",
                        claude_session_id: SecureRandom.uuid, codebase_path: "/tmp")
  end

  test "passwords never reach the bundle, argv or env" do
    seen = {}
    Designs::CrawlJob.runner = lambda do |argv:, env:, stdin:, out_dir:|
      seen = { argv: argv, env: env, stdin: stdin }
      File.write(File.join(out_dir, "crawl.json"), { roles: [ { name: "Admin", ok: true, pages: [] } ], styles: {} }.to_json)
      [ "", "", 0 ]
    end
    Designs::CrawlJob.perform_now(@setup.id)
    assert_includes JSON.parse(seen[:stdin])["roles"].first["password"], "s3cret-pass"
    assert_not_includes seen[:argv].join(" "), "s3cret-pass"
    assert_not_includes seen[:env].values.join(" "), "s3cret-pass"
    assert @setup.reload.crawled_at
    assert File.exist?(File.join(@setup.crawl_dir, "crawl.json"))
  end

  # Ruling P5-R3, P5-R1: under the project's designs folder, and read-only.
  test "the bundle lands under the project's designs folder and is sealed" do
    Designs::CrawlJob.runner = lambda do |out_dir:, **|
      File.write(File.join(out_dir, "crawl.json"), { roles: [ { name: "Admin", ok: true, pages: [] } ], styles: {} }.to_json)
      [ "", "", 0 ]
    end
    Designs::CrawlJob.perform_now(@setup.id)
    crawl_dir = @setup.reload.crawl_dir
    assert crawl_dir.start_with?(File.join(@project.designs_dir, "design-crawls") + "/")
    assert_equal "444", format("%o", File.stat(File.join(crawl_dir, "crawl.json")).mode & 0o777)
    assert_equal "555", format("%o", File.stat(crawl_dir).mode & 0o777)
    assert_not @setup.crawling?
  end

  test "a failed role is recorded and the rest continue" do
    session = setup_chat
    @project.design_setup_roles.create!(name: "Viewer", login_url: "https://app.test/login", username: "v", password: "other-pass")
    Designs::CrawlJob.runner = lambda do |out_dir:, **|
      File.write(File.join(out_dir, "crawl.json"), { roles: [
        { name: "Admin", ok: true, pages: [ { url: "https://app.test/", title: "Home" } ] },
        { name: "Viewer", ok: false, error: "login failed" }
      ], styles: {} }.to_json)
      [ "", "", 0 ]
    end
    Designs::CrawlJob.perform_now(@setup.id)
    assert @setup.reload.crawled_at
    assert_nil @setup.crawl_error
    assert_equal "Crawled 1 page as Admin. Viewer could not be crawled: login failed.", session.chat_messages.last.content
  end

  test "a crawl where every role failed records the error" do
    Designs::CrawlJob.runner = ->(**) { [ "", "all logins failed", 2 ] }
    Designs::CrawlJob.perform_now(@setup.id)
    assert_match(/all logins failed/, @setup.reload.crawl_error)
    assert_nil @setup.crawled_at
  end

  # Ruling P5-R5: a belt for "never logged".
  test "a password in the crawler's error output is scrubbed before it is saved" do
    Designs::CrawlJob.runner = ->(**) { [ "", "TimeoutError while typing s3cret-pass into #password", 2 ] }
    Designs::CrawlJob.perform_now(@setup.id)
    assert_not_includes @setup.reload.crawl_error, "s3cret-pass"
    assert_includes @setup.crawl_error, "[password]"
  end
end
