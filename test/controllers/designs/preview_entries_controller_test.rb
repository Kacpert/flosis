require "test_helper"

class Designs::PreviewEntriesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @root = Pathname(Dir.mktmpdir("preview"))
    ENV["DESIGNS_PREVIEW_ROOT"] = @root.to_s
    ENV["DESIGNS_PREVIEW_URL"] = "http://www.example.com"
    @project = projects(:jira_project)
    @project.update!(design_preview_token: "t0k")
    write("master/index.html", "<p>master</p>")
    write("master/designs/jobs.html", "<p>jobs</p>")
    write("REC-1/index.html", "<p>approved REC-1</p>")
  end

  teardown do
    ENV.delete("DESIGNS_PREVIEW_ROOT")
    ENV.delete("DESIGNS_PREVIEW_URL")
    FileUtils.remove_entry(@root)
  end

  test "a lasting link asks whoever opens it to sign in first" do
    get "/test-workspace/elvium/design/designs/jobs.html"
    assert_redirected_to new_session_path
  end

  test "someone the Workshop shows the project to is sent on to the page under a grant, and it opens" do
    sign_in_as(users(:two))
    get "/test-workspace/elvium/design/designs/jobs.html?ctx=admin"
    grant = assert_granted("master", "designs/jobs.html?ctx=admin")
    get "/test-workspace/elvium/#{grant}/design/designs/jobs.html"
    assert_equal "<p>jobs</p>", response.body
  end

  test "the project's link opens master, and a task's opens its last approved version" do
    sign_in_as(users(:one))
    get "/test-workspace/elvium/design/"
    assert_granted("master", "")
    get "/test-workspace/elvium/REC-1/design/"
    assert_granted("REC-1", "")
  end

  test "a project the Workshop does not show this person, or one the link misnames, is not found" do
    ProjectMembership.where(user: users(:workspace_client_user), project: @project).delete_all
    sign_in_as(users(:workspace_client_user))
    get "/test-workspace/elvium/design/"
    assert_response :not_found

    sign_in_as(users(:one))
    [ "/other-workspace/elvium/design/", "/test-workspace/other-project/design/" ].each do |path|
      get path
      assert_response :not_found, path
    end
  end

  test "a version that was never published is not found" do
    sign_in_as(users(:one))
    get "/test-workspace/elvium/REC-2/design/"
    assert_response :not_found
  end

  private

  # The grant the response sent its reader on with, after checking it names
  # this project and the slot, and that the page and the query went along.
  def assert_granted(slot, page)
    assert_response :redirect
    match = %r{\Ahttp://www\.example\.com/test-workspace/elvium/(#{Designs::PreviewGrant::FORMAT.source})/design/(.*)\z}.match(response.location)
    assert match, response.location
    assert_equal [ @project, slot ], Designs::PreviewGrant.read(match[1])
    assert_equal page, match[2]
    match[1]
  end

  def write(path, content)
    file = @root.join("t0k", path)
    FileUtils.mkdir_p(file.dirname)
    File.write(file, content)
  end
end
