require "test_helper"

class Designs::PreviewsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @root = Pathname(Dir.mktmpdir("preview"))
    ENV["DESIGNS_PREVIEW_ROOT"] = @root.to_s
    @project = projects(:jira_project)
    @project.update!(design_preview_token: "t0k")
    write("master/index.html", "<p>master</p>")
    write("master/designs/jobs.html", "<p>jobs</p>")
    write("master/runtime/flosis.js", "console.log(1)")
    write("master/designs/contexts.json", "{}")
    write("master/design-system/theme.css", "a{}")
    write("master/design-system/logo.svg", "<svg/>")
    write("wip/REC-1/index.html", "<p>work in progress</p>")
    @grant = Designs::PreviewGrant.issue(@project, "master")
  end

  teardown do
    ENV.delete("DESIGNS_PREVIEW_ROOT")
    FileUtils.remove_entry(@root)
  end

  test "a page is served from the slot its grant names, whatever the link names the organization and the project" do
    get "/acme/hiring/#{@grant}/design/designs/jobs.html"
    assert_response :success
    assert_equal "<p>jobs</p>", response.body
    get "/other/names/#{Designs::PreviewGrant.issue(@project, "wip/REC-1")}/design/index.html"
    assert_equal "<p>work in progress</p>", response.body
  end

  # The page is Claude's, with scripts anyone who can push to the design repo
  # can change. Sandboxed, it runs as an opaque origin: no cookies, storage or
  # pages of the app. Its own files are then fetched across origins.
  test "every response is sandboxed, without the app's origin, and its files may be fetched by the sandboxed page" do
    [ "/acme/hiring/#{@grant}/design/index.html", "/acme/hiring/#{@grant}/design/missing.html" ].each do |path|
      get path
      policy = response.headers["Content-Security-Policy"]
      assert_includes policy, "sandbox allow-scripts allow-forms allow-popups allow-modals", path
      assert_not_includes policy, "allow-same-origin", path
      assert_not_includes policy, "allow-top-navigation", path
      assert_includes policy, "frame-ancestors 'self'", path
      assert_equal "*", response.headers["Access-Control-Allow-Origin"], path
      assert_equal "no-referrer", response.headers["Referrer-Policy"], path
      assert_equal "noindex, nofollow", response.headers["X-Robots-Tag"], path
      assert_equal "nosniff", response.headers["X-Content-Type-Options"], path
    end
  end

  # The sandboxed page's requests carry no session: the grant is what lets
  # them through, and nothing here sets a cookie.
  test "no one has to be signed in, and nothing is written to a cookie" do
    get "/acme/hiring/#{@grant}/design/runtime/flosis.js"
    assert_response :success
    assert_nil response.headers["Set-Cookie"]
  end

  test "each file goes out as its kind" do
    {
      "index.html" => "text/html", "runtime/flosis.js" => "text/javascript", "designs/contexts.json" => "application/json",
      "design-system/theme.css" => "text/css", "design-system/logo.svg" => "image/svg+xml"
    }.each do |path, type|
      get "/acme/hiring/#{@grant}/design/#{path}"
      assert_equal type, response.media_type, path
    end
  end

  # A page's relative links resolve against its folder, so a folder is only
  # opened at its slash.
  test "a folder opens at its index.html, and a folder without its slash is sent to it, query and all" do
    get "/acme/hiring/#{@grant}/design/"
    assert_equal "<p>master</p>", response.body
    get "/acme/hiring/#{@grant}/design?ctx=admin"
    assert_redirected_to "/acme/hiring/#{@grant}/design/?ctx=admin"
    get "/acme/hiring/#{@grant}/design/designs?ctx=admin"
    assert_redirected_to "/acme/hiring/#{@grant}/design/designs/?ctx=admin"
  end

  test "a grant that was changed, made up or ran out opens nothing" do
    travel_to(Time.current + Designs::PreviewGrant::LIFETIME + 1.minute) do
      get "/acme/hiring/#{@grant}/design/index.html"
      assert_response :not_found
      assert_match(/run out/, response.body)
    end
    get "/acme/hiring/#{@grant.sub("master", "REC-1")}/design/index.html"
    assert_response :not_found
    assert_no_match(/master/, response.body)
  end

  test "a dotfile, a half-published copy, a path out of the slot and a link that leaves it are not found" do
    write("master/.htaccess", "Options +ExecCGI")
    write(".staging-master-1/index.html", "staging")
    write("REC-9/index.html", "another slot")
    File.symlink(@root.join("t0k/REC-9/index.html"), @root.join("t0k/master/linked.html"))
    [
      "/acme/hiring/#{@grant}/design/.htaccess",
      "/acme/hiring/#{@grant}/design/%2e%2e/REC-9/index.html",
      "/acme/hiring/#{@grant}/design/%2e%2e/.staging-master-1/index.html",
      "/acme/hiring/#{@grant}/design/linked.html",
      "/acme/hiring/#{@grant}/design/nothing-here.html"
    ].each do |path|
      get path
      assert_response :not_found, path
      assert_no_match(/another slot|staging|ExecCGI/, response.body, path)
    end
  end

  # Every browser that allow_browser calls modern honours the sandbox; an
  # older one could run the page as the app itself, so it gets nothing.
  test "a browser too old to honour the sandbox is refused" do
    get "/acme/hiring/#{@grant}/design/index.html",
        headers: { "User-Agent" => "Mozilla/5.0 (Windows NT 6.1) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/49.0.2623.112 Safari/537.36" }
    assert_response :not_acceptable
    assert_not_includes response.body, "<p>master</p>"
  end

  private

  def write(path, content)
    file = @root.join("t0k", path)
    FileUtils.mkdir_p(file.dirname)
    File.write(file, content)
  end
end
