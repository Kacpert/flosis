require "test_helper"
require "webmock/minitest"

class Designs::JiraLinksTest < ActiveSupport::TestCase
  include DesignRepoTestHelper

  setup do
    WebMock.disable_net_connect!
    ENV["DESIGNS_PREVIEW_URL"] = "https://preview.example"
  end

  teardown do
    WebMock.reset!
    WebMock.allow_net_connect!
    ENV.delete("DESIGNS_PREVIEW_URL")
  end

  # A task whose design thread changed the given screens against master.
  def thread_task(repo, files = { "designs/admin/jobs.html" => "<title>Jobs</title><p>new</p>" })
    task = tasks(:jira_task)
    task.update!(project: repo.project, external_reference: "REC-1")
    repo.project.update!(jira_site: "acme.atlassian.net", jira_email: "j@acme.test", jira_api_token: "jt", design_preview_token: "t0k")
    thread = DesignThread.create!(project: repo.project, task: task, author: users(:one), title: "Jobs", branch: "design/REC-1-jobs",
                                  base_sha: repo.head("master"))
    commit_files(repo, repo.worktree!(thread.branch, from: thread.base_sha), files)
    task
  end

  test "a link to the task's designs plus one per screen its thread changed, with the project's own Jira" do
    with_design_remote do |repo, remote|
      seed_master(repo)
      task = thread_task(repo)
      stub_request(:get, "https://acme.atlassian.net/rest/api/3/issue/REC-1/remotelink").to_return(status: 200, body: "[]")
      posts = stub_request(:post, "https://acme.atlassian.net/rest/api/3/issue/REC-1/remotelink").to_return(status: 200, body: "{}")
      result = with_remote_url(remote) { Designs::JiraLinks.new(task).sync! }
      assert result[:ok], result[:error]
      assert_requested posts, times: 2
      assert_requested(:post, "https://acme.atlassian.net/rest/api/3/issue/REC-1/remotelink") { |req|
        body = JSON.parse(req.body)
        body["globalId"] == "flosis-design:#{repo.project.id}:REC-1:designs/admin/jobs.html" &&
          body["object"]["url"] == "https://preview.example/test-workspace/elvium/REC-1/design/designs/admin/jobs.html" &&
          body["object"]["title"] == "Design · Admin › Jobs"
      }
      assert_requested(:post, "https://acme.atlassian.net/rest/api/3/issue/REC-1/remotelink") { |req|
        body = JSON.parse(req.body)
        body["globalId"] == "flosis-design:#{repo.project.id}:REC-1:index" && body["object"]["title"] == "Designs · design/REC-1-jobs"
      }
    end
  end

  test "a screen the thread no longer changes loses its link" do
    with_design_remote do |repo, remote|
      seed_master(repo)
      task = thread_task(repo)
      stale = "flosis-design:#{repo.project.id}:REC-1:designs/old.html:admin"
      other = "flosis-design:#{repo.project.id}:REC-10:index"
      stub_request(:get, %r{/remotelink\z}).to_return(status: 200, body: [ { globalId: stale, id: 9 }, { globalId: other, id: 10 },
                                                                            { id: 11 } ].to_json)
      stub_request(:post, %r{/remotelink\z}).to_return(status: 200, body: "{}")
      delete = stub_request(:delete, %r{/remotelink\?globalId=}).to_return(status: 204)
      with_remote_url(remote) { Designs::JiraLinks.new(task).sync! }
      assert_requested delete, times: 1
      assert_requested :delete, "https://acme.atlassian.net/rest/api/3/issue/REC-1/remotelink?globalId=#{CGI.escape(stale)}"
    end
  end

  test "syncing links never writes the description" do
    with_design_remote do |repo, remote|
      seed_master(repo)
      task = thread_task(repo)
      stub_request(:get, %r{/remotelink\z}).to_return(status: 200, body: "[]")
      stub_request(:post, %r{/remotelink\z}).to_return(status: 200, body: "{}")
      with_remote_url(remote) { Designs::JiraLinks.new(task).sync! }
      assert_not_requested :put, %r{/rest/api/3/issue/REC-1\z}
    end
  end

  test "the first failure stops the sync and is returned" do
    with_design_remote do |repo, remote|
      seed_master(repo)
      task = thread_task(repo)
      posts = stub_request(:post, %r{/remotelink\z}).to_return(status: 403, body: "{}")
      result = with_remote_url(remote) { Designs::JiraLinks.new(task).sync! }
      assert_not result[:ok]
      assert_match(/403/, result[:error])
      assert_requested posts, times: 1
    end
  end

  test "a project without Jira skips links with a reason" do
    with_design_remote do |repo, _|
      task = tasks(:jira_task)
      task.update!(project: repo.project)
      repo.project.update!(jira_site: nil, jira_email: nil, jira_api_token: nil)
      ENV.delete("JIRA_DOMAIN")
      assert_equal "This project isn't connected to Jira.", Designs::JiraLinks.new(task).sync![:error]
    end
  end

  test "a task with no Jira issue yet skips links with a reason" do
    with_design_remote do |repo, _|
      task = tasks(:jira_task)
      task.update!(project: repo.project, external_reference: nil)
      repo.project.update!(jira_site: "acme.atlassian.net", jira_email: "j@acme.test", jira_api_token: "jt")
      assert_equal "This task has no Jira issue yet.", Designs::JiraLinks.new(task).sync![:error]
    end
  end

  test "the job sends a task's links, and a failure is said in its thread" do
    with_design_remote do |repo, remote|
      seed_master(repo)
      task = thread_task(repo)
      session = ChatSession.create!(project: repo.project, workspace: repo.project.workspace, user: users(:one), purpose: "designs_thread",
                                    claude_session_id: SecureRandom.uuid, codebase_path: "/tmp")
      task.design_thread.update!(chat_session: session)
      stub_request(:get, %r{/remotelink\z}).to_return(status: 200, body: "[]")
      stub_request(:post, %r{/remotelink\z}).to_return(status: 500, body: "{}")
      with_remote_url(remote) { Designs::SyncJiraLinksJob.perform_now(task.id) }
      assert_match(/\AThe Jira links could not be updated: .*500/, session.chat_messages.where(kind: "system").last.content)
    end
  end

  test "a task with no design thread has no links to send" do
    with_design_remote do |repo, remote|
      seed_master(repo)
      task = tasks(:jira_task)
      task.update!(project: repo.project, external_reference: "REC-1")
      repo.project.update!(jira_site: "acme.atlassian.net", jira_email: "j@acme.test", jira_api_token: "jt")
      assert_equal "This task has no design thread yet.", with_remote_url(remote) { Designs::JiraLinks.new(task).sync![:error] }
    end
  end

end
