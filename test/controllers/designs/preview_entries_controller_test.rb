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

  test "a task's lasting link opens its design thread's branch" do
    task = tasks(:jira_task)
    task.update!(project: @project, external_reference: "SP-1051")
    DesignThread.create!(project: @project, task: task, author: users(:one), title: "x", branch: "design/SP-1051-inline")
    write("design/SP-1051-inline/designs/candidate/apply.html", "<p>apply</p>")
    sign_in_as(users(:one))

    get "/test-workspace/elvium/SP-1051/design/designs/candidate/apply.html"
    assert_granted("design/SP-1051-inline", "designs/candidate/apply.html")
  end

  # Accept designs (2026-11-21): once accepted, a task's link opens the copy of
  # its merge commit, and with no page, the list of what changed.
  def accepted_task(key: "SP-1051")
    task = tasks(:jira_task)
    task.update!(project: @project, external_reference: key)
    thread = DesignThread.create!(project: @project, task: task, author: users(:one), title: "x",
                                  branch: "design/SP-1051-inline", status: "merged")
    write("design/SP-1051-inline/designs/candidate/apply.html", "<p>work in progress</p>")
    DesignMerge.create!(project: @project, task: task, design_thread: thread, sha: "a" * 40, title: "x", branch: thread.branch,
                        how: "manual", merged_at: Time.current, slot: "accepted/#{thread.id}")
    write("accepted/#{thread.id}/__flosis/changes.html", "<p>what changed</p>")
    write("accepted/#{thread.id}/designs/candidate/apply.html", "<p>accepted</p>")
    [ task, thread ]
  end

  test "a task's link opens its accepted copy once the thread is accepted, and with no page its changes" do
    _, thread = accepted_task
    sign_in_as(users(:one))

    get "/test-workspace/elvium/SP-1051/design"
    assert_granted("accepted/#{thread.id}", "__flosis/changes.html")
    get "/test-workspace/elvium/SP-1051/design/designs/candidate/apply.html"
    assert_granted("accepted/#{thread.id}", "designs/candidate/apply.html")
  end

  test "after the thread is unlinked from its task, the link still opens the accepted copy" do
    _, thread = accepted_task
    thread.update!(task: nil, status: "deleted")
    sign_in_as(users(:one))

    get "/test-workspace/elvium/SP-1051/design/designs/candidate/apply.html"
    assert_granted("accepted/#{thread.id}", "designs/candidate/apply.html")
  end

  test "a task with no key links by task-<id>" do
    task, thread = accepted_task(key: nil)
    sign_in_as(users(:one))

    get "/test-workspace/elvium/task-#{task.id}/design"
    assert_granted("accepted/#{thread.id}", "__flosis/changes.html")
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

  # Kacper, 2026-11-23: a tab opened from the Designs screen the night before
  # had run out. Its grant is renewed for whoever signs in and may see the
  # project, to the same slot and page, work in progress included.
  test "a grant that ran out is renewed for the same slot and page once its reader signs in" do
    write("design/task-551-billing/designs/admin/billing.html", "<p>billing</p>")
    grant = Designs::PreviewGrant.issue(@project, "design/task-551-billing", now: 2.days.ago)
    path = "/test-workspace/elvium/#{grant}/renew/designs/admin/billing.html?ctx=admin"

    get path
    assert_redirected_to new_session_path

    sign_in_as(users(:two))
    get path
    renewed = assert_granted("design/task-551-billing", "designs/admin/billing.html?ctx=admin")
    assert_not_equal grant, renewed
    get "/test-workspace/elvium/#{renewed}/design/designs/admin/billing.html"
    assert_equal "<p>billing</p>", response.body
  end

  test "a renewal is not found for someone the Workshop does not show the project to, a forged grant, or a slot taken down" do
    grant = Designs::PreviewGrant.issue(@project, "master", now: 2.days.ago)
    ProjectMembership.where(user: users(:workspace_client_user), project: @project).delete_all
    sign_in_as(users(:workspace_client_user))
    get "/test-workspace/elvium/#{grant}/renew/index.html"
    assert_response :not_found

    sign_in_as(users(:one))
    get "/test-workspace/elvium/#{grant}/renew/index.html"
    assert_granted("master", "index.html")
    forged = grant.sub(/.\z/) { |last| last == "0" ? "1" : "0" }
    get "/test-workspace/elvium/#{forged}/renew/index.html"
    assert_response :not_found
    get "/test-workspace/elvium/#{Designs::PreviewGrant.issue(@project, "REC-2", now: 2.days.ago)}/renew/index.html"
    assert_response :not_found
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
