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

  test ".for builds from a workspace" do
    w = workspaces(:one)
    w.update!(github_token: "t", github_repo: "acme/widgets")
    assert GithubClient.for(w).configured?
  end
end
