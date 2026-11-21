require "test_helper"
require "webmock/minitest"

class GithubClientTest < ActiveSupport::TestCase
  def client
    GithubClient.new(token: "tok", repo: "acme/widgets")
  end

  test "configured? requires token and repo" do
    assert_not GithubClient.new(token: nil, repo: "a/b").configured?
    assert_not GithubClient.new(token: "t", repo: nil).configured?
    assert client.configured?
  end

  test "open_pull_requests parses the list" do
    stub_request(:get, "https://api.github.com/repos/acme/widgets/pulls?state=open&per_page=50")
      .with(headers: { "Authorization" => "Bearer tok", "Accept" => "application/vnd.github+json" })
      .to_return(status: 200, body: [ { number: 7, draft: false } ].to_json)
    prs = client.open_pull_requests
    assert_equal 7, prs.first["number"]
  end

  test "create_review posts the review payload and returns true on 200" do
    stub = stub_request(:post, "https://api.github.com/repos/acme/widgets/pulls/7/reviews")
      .with(body: hash_including("event" => "COMMENT", "body" => "🤖 Automated AI review"))
      .to_return(status: 200, body: "{}")
    assert client.create_review(7, body: "🤖 Automated AI review", event: "COMMENT",
      comments: [ { path: "a.rb", line: 3, side: "RIGHT", body: "x" } ])
    assert_requested stub
  end

  test "create_review returns false on error without raising" do
    stub_request(:post, "https://api.github.com/repos/acme/widgets/pulls/7/reviews").to_return(status: 422, body: "{}")
    assert_not client.create_review(7, body: "b", event: "COMMENT", comments: [])
  end

  test "health_check ok on 200" do
    stub_request(:get, "https://api.github.com/repos/acme/widgets").to_return(status: 200, body: "{}")
    assert_equal({ ok: true }, client.health_check)
  end

  test "health_check reports error on 401" do
    stub_request(:get, "https://api.github.com/repos/acme/widgets").to_return(status: 401, body: "{}")
    result = client.health_check
    assert_not result[:ok]
    assert_match(/401/, result[:error])
  end

  test "health_check reports error on network failure" do
    stub_request(:get, "https://api.github.com/repos/acme/widgets").to_raise(SocketError.new("boom"))
    assert_not client.health_check[:ok]
  end

  # Finish writes a task's branch through the Git Data API (2026-11-21).
  test "the default branch and a branch's head, with none for a branch GitHub does not have" do
    stub_request(:get, "https://api.github.com/repos/acme/widgets").to_return(status: 200, body: { default_branch: "main" }.to_json)
    stub_request(:get, "https://api.github.com/repos/acme/widgets/git/ref/heads/feat/x-1")
      .to_return(status: 200, body: { object: { sha: "abc" } }.to_json)
    stub_request(:get, "https://api.github.com/repos/acme/widgets/git/ref/heads/feat/none").to_return(status: 404, body: { message: "Not Found" }.to_json)

    assert_equal "main", client.default_branch
    assert_equal "abc", client.branch_sha("feat/x-1")
    assert_nil client.branch_sha("feat/none")
  end

  test "a commit's tree, a folder's files, and none for a folder that is not there" do
    stub_request(:get, "https://api.github.com/repos/acme/widgets/git/commits/abc").to_return(status: 200, body: { tree: { sha: "t1" } }.to_json)
    stub_request(:get, "https://api.github.com/repos/acme/widgets/contents/tasks/X-1/attachments?ref=feat/x-1")
      .to_return(status: 200, body: [ { type: "file", path: "tasks/X-1/attachments/a.png" }, { type: "dir", path: "tasks/X-1/attachments/d" } ].to_json)
    stub_request(:get, "https://api.github.com/repos/acme/widgets/contents/tasks/X-2/attachments?ref=feat/x-2").to_return(status: 404, body: "{}")

    assert_equal "t1", client.commit_tree_sha("abc")
    assert_equal [ "tasks/X-1/attachments/a.png" ], client.folder_paths("tasks/X-1/attachments", ref: "feat/x-1")
    assert_equal [], client.folder_paths("tasks/X-2/attachments", ref: "feat/x-2")
  end

  test "blobs, trees, commits and refs are written, and a ref is moved without force" do
    blob = stub_request(:post, "https://api.github.com/repos/acme/widgets/git/blobs")
           .with(body: { content: Base64.strict_encode64("hi"), encoding: "base64" }.to_json).to_return(status: 201, body: { sha: "b1" }.to_json)
    tree = stub_request(:post, "https://api.github.com/repos/acme/widgets/git/trees")
           .with(body: hash_including("base_tree" => "t0")).to_return(status: 201, body: { sha: "t1" }.to_json)
    commit = stub_request(:post, "https://api.github.com/repos/acme/widgets/git/commits")
             .with(body: hash_including("message" => "X-1: task", "parents" => [ "p0" ])).to_return(status: 201, body: { sha: "c1" }.to_json)
    create = stub_request(:post, "https://api.github.com/repos/acme/widgets/git/refs")
             .with(body: { ref: "refs/heads/feat/x-1", sha: "c1" }.to_json).to_return(status: 201, body: "{}")
    move = stub_request(:patch, "https://api.github.com/repos/acme/widgets/git/refs/heads/feat/x-1")
           .with(body: { sha: "c2", force: false }.to_json).to_return(status: 200, body: "{}")

    assert_equal "b1", client.create_blob("hi")
    assert_equal "t1", client.create_tree(base_tree: "t0", entries: [ { path: "a", mode: "100644", type: "blob", sha: "b1" } ])
    assert_equal "c1", client.create_commit(message: "X-1: task", tree: "t1", parents: [ "p0" ])
    client.create_ref("feat/x-1", "c1")
    client.update_ref("feat/x-1", "c2")
    [ blob, tree, commit, create, move ].each { |stub| assert_requested stub }
  end

  test "a refusal raises with GitHub's status and reason" do
    stub_request(:post, "https://api.github.com/repos/acme/widgets/git/refs")
      .to_return(status: 403, body: { message: "Resource not accessible by personal access token" }.to_json)

    error = assert_raises(GithubClient::Error) { client.create_ref("feat/x-1", "c1") }
    assert_equal 403, error.status
    assert_match(/Resource not accessible/, error.message)
  end
end
