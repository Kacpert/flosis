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

  # A task's link names the project and the task's key, no organization
  # (Kacper, 2026-11-23): /<project>/<KEY>, a screen /<project>/<KEY>/<context>/<screen>.
  test "a task's link asks whoever opens it to sign in first" do
    get "/elvium/SP-1051/candidate/apply"
    assert_redirected_to new_session_path
  end

  test "a task's link opens its design thread's branch, a screen by its context and name" do
    task = tasks(:jira_task)
    task.update!(project: @project, external_reference: "SP-1051")
    DesignThread.create!(project: @project, task: task, author: users(:one), title: "x", branch: "design/SP-1051-inline")
    write("design/SP-1051-inline/designs/candidate/apply.html", "<p>apply</p>")
    sign_in_as(users(:one))

    get "/elvium/SP-1051/candidate/apply?ctx=admin"
    assert_granted("design/SP-1051-inline", "designs/candidate/apply.html?ctx=admin")
    get "/elvium/SP-1051/designs/candidate/apply.html"
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

    get "/elvium/SP-1051"
    assert_granted("accepted/#{thread.id}", "__flosis/changes.html")
    get "/elvium/SP-1051/candidate/apply"
    assert_granted("accepted/#{thread.id}", "designs/candidate/apply.html")
  end

  # Kacper (2026-11-23): /wip shows the current work even when it is not
  # accepted yet: the link to send someone.
  test "/wip opens the thread's branch even once accepted, and the version when no branch is published" do
    _, thread = accepted_task
    sign_in_as(users(:one))

    get "/elvium/SP-1051/wip/candidate/apply"
    assert_granted("design/SP-1051-inline", "designs/candidate/apply.html")
    get "/elvium/SP-1051/wip"
    assert_granted("design/SP-1051-inline", "")

    FileUtils.rm_rf(@root.join("t0k", "design"))
    get "/elvium/SP-1051/wip/candidate/apply"
    assert_granted("accepted/#{thread.id}", "designs/candidate/apply.html")
  end

  test "after the thread is unlinked from its task, the link still opens the accepted copy" do
    _, thread = accepted_task
    thread.update!(task: nil, status: "deleted")
    sign_in_as(users(:one))

    get "/elvium/SP-1051/candidate/apply"
    assert_granted("accepted/#{thread.id}", "designs/candidate/apply.html")
  end

  test "a task with no key links by task-<id>" do
    task, thread = accepted_task(key: nil)
    sign_in_as(users(:one))

    get "/elvium/task-#{task.id}"
    assert_granted("accepted/#{thread.id}", "__flosis/changes.html")
  end

  test "the project's link opens master, and a task's key opens the version published under it" do
    sign_in_as(users(:one))
    get "/test-workspace/elvium/design/"
    assert_granted("master", "", organization: "test-workspace")
    get "/elvium/REC-1"
    assert_granted("REC-1", "")
  end

  # The same project name and key in two of a person's organizations is rare
  # (Kacper, 2026-11-23): they pick one, and the link names it with ?org=.
  test "a project name and key in two of a person's organizations asks which, and ?org= opens one" do
    accepted_task
    other = Project.create!(name: "Elvium", workspace: workspaces(:two), color: "#000000", currency: "USD", show_in_workshop: true,
                            design_preview_token: "t1k")
    Task.create!(project: other, name: "Their task", external_reference: "SP-1051")
    write("SP-1051/index.html", "<p>theirs</p>", token: "t1k")
    WorkspaceMembership.create!(user: users(:one), workspace: workspaces(:two), workspace_admin: true)
    sign_in_as(users(:one))

    get "/elvium/SP-1051/candidate/apply"
    assert_response :success
    assert_select "a[href=?]", "/elvium/SP-1051/candidate/apply?org=test-workspace"
    assert_select "a[href=?]", "/elvium/SP-1051/candidate/apply?org=other-workspace"

    get "/elvium/SP-1051?org=other-workspace"
    assert_granted("SP-1051", "", project: other)
  end

  test "a task's link is not found under a project name the person does not see, or for a task with nothing published" do
    accepted_task
    ProjectMembership.where(user: users(:workspace_client_user), project: @project).delete_all
    sign_in_as(users(:workspace_client_user))
    get "/elvium/SP-1051"
    assert_response :not_found

    sign_in_as(users(:one))
    [ "/other-project/SP-1051", "/elvium/SP-9999", "/elvium/SP-1051?org=other-workspace" ].each do |path|
      get path
      assert_response :not_found, path
    end
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
    get "/elvium/REC-2"
    assert_response :not_found
  end

  private

  # The grant the response sent its reader on with, after checking it names
  # this project and the slot, and that the page and the query went along.
  def assert_granted(slot, page, project: @project, organization: nil)
    assert_response :redirect
    names = "#{organization || Designs::Publisher.label(project.workspace.name, "organization")}/#{Designs::Publisher.label(project.name, "project")}"
    match = %r{\Ahttp://www\.example\.com/#{names}/(#{Designs::PreviewGrant::FORMAT.source})/design/(.*)\z}.match(response.location)
    assert match, response.location
    assert_equal [ project, slot ], Designs::PreviewGrant.read(match[1])
    assert_equal page, match[2]
    match[1]
  end

  def write(path, content, token: "t0k")
    file = @root.join(token, path)
    FileUtils.mkdir_p(file.dirname)
    File.write(file, content)
  end
end
