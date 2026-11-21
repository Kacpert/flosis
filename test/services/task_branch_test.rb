require "test_helper"
require "webmock/minitest"

# Finish creates the task's branch in the app's repo (2026-11-21): one commit
# with tasks/<KEY>/<key>.md and its attachments, never forced.
class TaskBranchTest < ActiveSupport::TestCase
  API = "https://api.github.com/repos/acme/app".freeze
  BRANCH = "feat/scrum-70-add-token-calculations".freeze

  setup do
    WebMock.disable_net_connect!
    @project = projects(:jira_project)
    @project.update!(github_repo: "acme/app", github_token: "tok", github_branch: nil)
    @task = @project.tasks.create!(name: "SCRUM-70 Add token calculations", external_reference: "SCRUM-70", external_type: "jira")
    @task.task_drafts.create!(source: TaskDraft::REFINE_SOURCE, origin: "ai", version: 5, content: "## Costs\n\nIntro.").make_current!
  end

  teardown do
    WebMock.reset!
    WebMock.allow_net_connect!
  end

  def stub_json(method, path, body, status: 200)
    stub_request(method, "#{API}#{path}").to_return(status: status, body: body.to_json, headers: { "Content-Type" => "application/json" })
  end

  # A repo whose default branch is main at p0, its tree t0.
  def stub_base(branch_sha: nil, tree_after: "t1")
    branch_sha ? stub_json(:get, "/git/ref/heads/#{BRANCH}", { object: { sha: branch_sha } }) : stub_json(:get, "/git/ref/heads/#{BRANCH}", { message: "Not Found" }, status: 404)
    stub_json(:get, "", { default_branch: "main" })
    stub_json(:get, "/git/ref/heads/main", { object: { sha: "p0" } })
    stub_json(:get, "/git/commits/p0", { tree: { sha: "t0" } })
    stub_json(:get, "/git/commits/c1", { tree: { sha: "t1" } })
    stub_json(:post, "/git/blobs", { sha: "b1" }, status: 201)
    stub_json(:post, "/git/trees", { sha: tree_after }, status: 201)
  end

  test "a new branch from the default branch holds the task file" do
    stub_base
    commit = stub_request(:post, "#{API}/git/commits").with(body: hash_including("message" => "SCRUM-70: task description v5", "parents" => [ "p0" ]))
                                                      .to_return(status: 201, body: { sha: "c1" }.to_json)
    ref = stub_request(:post, "#{API}/git/refs").with(body: { ref: "refs/heads/#{BRANCH}", sha: "c1" }.to_json).to_return(status: 201, body: "{}")

    result = TaskBranch.new(@task).push!

    assert_equal [ true, BRANCH, "c1", nil ], result.values_at(:ok, :branch, :sha, :error)
    assert_requested(:post, "#{API}/git/trees") { |req| JSON.parse(req.body)["tree"].map { |entry| entry["path"] } == [ "tasks/SCRUM-70/scrum-70.md" ] }
    assert_requested commit
    assert_requested ref
    @task.reload
    assert_equal [ BRANCH, "c1", nil ], [ @task.code_branch, @task.code_branch_sha, @task.code_branch_error ]
    assert @task.code_branch_pushed_at
  end

  test "Finish again adds a commit on top, drops attachments the task no longer has, and never forces" do
    @task.update!(code_branch: BRANCH)
    stub_base(branch_sha: "c1", tree_after: "t2")
    stub_json(:get, "/contents/tasks/SCRUM-70?ref=#{BRANCH}", [])
    stub_json(:get, "/contents/tasks/SCRUM-70/attachments?ref=#{BRANCH}", [ { type: "file", path: "tasks/SCRUM-70/attachments/old.png", sha: "o1" } ])
    stub_request(:post, "#{API}/git/commits").with(body: hash_including("parents" => [ "c1" ])).to_return(status: 201, body: { sha: "c2" }.to_json)
    move = stub_request(:patch, "#{API}/git/refs/heads/#{BRANCH}").with(body: { sha: "c2", force: false }.to_json).to_return(status: 200, body: "{}")

    assert TaskBranch.new(@task).push![:ok]
    assert_requested(:post, "#{API}/git/trees") { |req|
      JSON.parse(req.body)["tree"].any? { |entry| entry["path"] == "tasks/SCRUM-70/attachments/old.png" && entry["sha"].nil? }
    }
    assert_requested move
    assert_not_requested :post, "#{API}/git/refs"
    assert_equal "c2", @task.reload.code_branch_sha
  end

  test "nothing changed, nothing committed" do
    @task.update!(code_branch: BRANCH)
    stub_base(branch_sha: "c1", tree_after: "t1")
    stub_json(:get, "/contents/tasks/SCRUM-70?ref=#{BRANCH}", [])
    stub_json(:get, "/contents/tasks/SCRUM-70/attachments?ref=#{BRANCH}", [])

    assert_equal [ true, "c1" ], TaskBranch.new(@task).push!.values_at(:ok, :sha)
    assert_not_requested :post, "#{API}/git/commits"
  end

  test "a refused token is recorded with what it needs, and a retry after it succeeds" do
    stub_base
    stub_json(:post, "/git/commits", { sha: "c1" }, status: 201)
    stub_json(:post, "/git/refs", { message: "Resource not accessible by personal access token" }, status: 403)

    result = TaskBranch.new(@task).push!
    assert_not result[:ok]
    assert_equal "The project's GitHub token can't write to acme/app (403). It needs Contents: write — Configuration › GitHub.",
                 @task.reload.code_branch_error
    assert_nil @task.code_branch_sha

    stub_json(:post, "/git/refs", {}, status: 201)
    assert TaskBranch.new(@task).push![:ok]
    assert_nil @task.reload.code_branch_error
  end

  test "a project without a GitHub repo and token says so" do
    @project.update!(github_repo: nil)
    result = TaskBranch.new(@task.reload).push!
    assert_not result[:ok]
    assert_match(/no GitHub repository/, result[:error])
  end

  # Review I4: whatever goes wrong on the way to GitHub is recorded, never a
  # 500 after Jira was written; a file the branch already holds is not sent
  # again.
  test "a dropped connection is recorded, not raised" do
    stub_base
    stub_request(:post, "#{API}/git/blobs").to_raise(Errno::ECONNRESET)

    result = TaskBranch.new(@task).push!
    assert_not result[:ok]
    assert_match(/Connection reset/, @task.reload.code_branch_error)
  end

  test "a file the branch already holds is not uploaded again" do
    @task.update!(code_branch: BRANCH)
    stub_base(branch_sha: "c1", tree_after: "t1")
    markdown = TaskFile.new(@task).markdown
    held = Digest::SHA1.hexdigest("blob #{markdown.bytesize}\0#{markdown}")
    stub_json(:get, "/contents/tasks/SCRUM-70?ref=#{BRANCH}", [ { type: "file", path: "tasks/SCRUM-70/scrum-70.md", sha: held } ])
    stub_json(:get, "/contents/tasks/SCRUM-70/attachments?ref=#{BRANCH}", [])

    assert TaskBranch.new(@task).push![:ok]
    assert_not_requested :post, "#{API}/git/blobs"
    assert_requested(:post, "#{API}/git/trees") { |req| JSON.parse(req.body)["tree"].first["sha"] == held }
  end

  # Review (re-graded): a new branch is created even when the base already
  # holds the same files, instead of saying so and creating nothing.
  test "a new branch whose files the base already holds is still created" do
    stub_base(tree_after: "t0")
    ref = stub_request(:post, "#{API}/git/refs").with(body: { ref: "refs/heads/#{BRANCH}", sha: "p0" }.to_json).to_return(status: 201, body: "{}")

    assert_equal [ true, "p0" ], TaskBranch.new(@task).push!.values_at(:ok, :sha)
    assert_requested ref
    assert_not_requested :post, "#{API}/git/commits"
  end
end
