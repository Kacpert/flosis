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

  def approved_task(repo, manifest)
    task = tasks(:jira_task)
    task.update!(project: repo.project, external_reference: "REC-1")
    repo.project.update!(jira_site: "acme.atlassian.net", jira_email: "j@acme.test", jira_api_token: "jt", design_preview_token: "t0k")
    dir = repo.worktree!("wip/REC-1")
    sha = commit_files(repo, dir, {
      "designs/contexts.json" => { dimensions: [ { id: "role", name: "Role", values: [ { id: "admin", name: "Admin" }, { id: "viewer", name: "Viewer" } ] } ] }.to_json,
      "designs/tasks/REC-1.json" => manifest.to_json,
      "designs/jobs.html" => "jobs"
    })
    repo.point!("design/REC-1", to: sha)
    task
  end

  test "an overview link plus one per screen and context, with the project's own Jira" do
    with_design_remote do |repo, remote|
      seed_master(repo)
      task = approved_task(repo, { screens: [ { path: "designs/jobs.html", title: "Jobs", contexts: %w[admin viewer] } ] })
      stub_request(:get, "https://acme.atlassian.net/rest/api/3/issue/REC-1/remotelink").to_return(status: 200, body: "[]")
      posts = stub_request(:post, "https://acme.atlassian.net/rest/api/3/issue/REC-1/remotelink").to_return(status: 200, body: "{}")
      result = with_remote_url(remote) { Designs::JiraLinks.new(task).sync! }
      assert result[:ok], result[:error]
      assert_requested posts, times: 3
      assert_requested(:post, "https://acme.atlassian.net/rest/api/3/issue/REC-1/remotelink") { |req|
        JSON.parse(req.body)["object"]["url"] == "https://preview.example/test-workspace/elvium/REC-1/design/designs/jobs.html?ctx=viewer"
      }
      assert_requested(:post, "https://acme.atlassian.net/rest/api/3/issue/REC-1/remotelink") { |req|
        body = JSON.parse(req.body)
        body["globalId"] == "flosis-design:#{repo.project.id}:REC-1:designs/jobs.html:viewer" &&
          body["object"]["title"] == "Design · Jobs · Viewer"
      }
      assert_requested(:post, "https://acme.atlassian.net/rest/api/3/issue/REC-1/remotelink") { |req|
        body = JSON.parse(req.body)
        body["globalId"] == "flosis-design:#{repo.project.id}:REC-1:index" && body["object"]["title"] == "Design · REC-1 · overview"
      }
    end
  end

  test "a screen that names no context gets one link, with the defaults" do
    with_design_remote do |repo, remote|
      seed_master(repo)
      task = approved_task(repo, { screens: [ { path: "designs/jobs.html", title: "Jobs" } ] })
      stub_request(:get, %r{/remotelink\z}).to_return(status: 200, body: "[]")
      posts = stub_request(:post, %r{/remotelink\z}).to_return(status: 200, body: "{}")
      with_remote_url(remote) { Designs::JiraLinks.new(task).sync! }
      assert_requested posts, times: 2
      assert_requested(:post, %r{/remotelink\z}) { |req| JSON.parse(req.body)["object"]["url"].end_with?("/designs/jobs.html?ctx=admin") }
    end
  end

  test "a screen gone from the manifest loses its link" do
    with_design_remote do |repo, remote|
      seed_master(repo)
      task = approved_task(repo, { screens: [] })
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
      task = approved_task(repo, { screens: [] })
      stub_request(:get, %r{/remotelink\z}).to_return(status: 200, body: "[]")
      stub_request(:post, %r{/remotelink\z}).to_return(status: 200, body: "{}")
      with_remote_url(remote) { Designs::JiraLinks.new(task).sync! }
      assert_not_requested :put, %r{/rest/api/3/issue/REC-1\z}
    end
  end

  test "the first failure stops the sync and is returned" do
    with_design_remote do |repo, remote|
      seed_master(repo)
      task = approved_task(repo, { screens: [ { path: "designs/jobs.html", title: "Jobs" } ] })
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

  test "the job records how the links went on the approval" do
    with_design_remote do |repo, remote|
      seed_master(repo)
      task = approved_task(repo, { screens: [] })
      approval = task.design_approvals.create!(user: users(:one), number: 1, tag: "approved/REC-1/1", design_sha: "a", master_sha: "b")
      stub_request(:get, %r{/remotelink\z}).to_return(status: 200, body: "[]")
      stub_request(:post, %r{/remotelink\z}).to_return(status: 500, body: "{}")
      with_remote_url(remote) { Designs::SyncJiraLinksJob.perform_now(approval.id) }
      assert_match(/500/, approval.reload.jira_links_error)
      assert_nil approval.jira_links_synced_at

      stub_request(:post, %r{/remotelink\z}).to_return(status: 200, body: "{}")
      with_remote_url(remote) { Designs::SyncJiraLinksJob.perform_now(approval.id) }
      assert_nil approval.reload.jira_links_error
      assert approval.jira_links_synced_at
    end
  end
end
