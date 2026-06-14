require "test_helper"

class PrReviewJobTest < ActiveJob::TestCase
  setup do
    @workspace = workspaces(:one)
    @workspace.update!(github_token: "t", github_repo: "acme/widgets", pr_review_enabled: true)
  end

  def fake_github(pr:, files: [ { "filename" => "a.rb", "patch" => "@@ -1 +1 @@\n+code" } ], commits: [])
    fake = Object.new
    captured = {}
    fake.define_singleton_method(:pull_request) { |_n| pr }
    fake.define_singleton_method(:pull_request_files) { |_n| files }
    fake.define_singleton_method(:pull_request_commits) { |_n| commits }
    fake.define_singleton_method(:create_review) { |n, body:, event:, comments:| captured.merge!(n: n, body: body, comments: comments); true }
    fake.define_singleton_method(:configured?) { true }
    fake.define_singleton_method(:captured) { captured }
    fake
  end

  def with_github(fake)
    orig = GithubClient.method(:for)
    GithubClient.define_singleton_method(:for) { |*_a, **_k| fake }
    yield
  ensure
    GithubClient.define_singleton_method(:for, orig)
  end

  def with_ai(json)
    orig = ClaudeCliService.instance_method(:start_session)
    ClaudeCliService.define_method(:start_session) { |**_kw| { session_id: "s", response: json } }
    yield
  ensure
    ClaudeCliService.define_method(:start_session, orig)
  end

  def pr_payload(number: 7, sha: "abc", draft: false)
    { "number" => number, "draft" => draft, "state" => "open", "title" => "DEV-836 thing", "body" => "",
      "head" => { "sha" => sha, "ref" => "dev-836-thing" } }
  end

  test "initial review caps at 4 comments and posts a review, recording the SHA" do
    fake = fake_github(pr: pr_payload(sha: "abc"))
    ai = [ 1, 2, 3, 4, 5 ].map { |i| { "path" => "a.rb", "line" => i, "comment" => "c#{i}" } }.to_json

    with_github(fake) do
      with_ai(ai) do
        PrReviewJob.perform_now(@workspace.id, 7, "initial")
      end
    end

    assert_equal 4, fake.captured[:comments].size
    assert_equal "🤖 Automated AI review", fake.captured[:body]
    review = PrReview.find_by(workspace: @workspace, pr_number: 7)
    assert_equal "abc", review.last_reviewed_sha
    assert review.initial_done
  end

  test "followup caps at 2 comments" do
    PrReview.create!(workspace: @workspace, pr_number: 7, last_reviewed_sha: "old", initial_done: true)
    fake = fake_github(pr: pr_payload(sha: "new"), commits: [ { "sha" => "new" } ])
    ai = [ 1, 2, 3 ].map { |i| { "path" => "a.rb", "line" => i, "comment" => "c#{i}" } }.to_json

    with_github(fake) do
      with_ai(ai) do
        PrReviewJob.perform_now(@workspace.id, 7, "followup")
      end
    end

    assert_equal 2, fake.captured[:comments].size
    assert_equal "new", PrReview.find_by(workspace: @workspace, pr_number: 7).last_reviewed_sha
  end

  test "no issues posts the no-issues review" do
    fake = fake_github(pr: pr_payload(sha: "abc"))
    with_github(fake) do
      with_ai("[]") do
        PrReviewJob.perform_now(@workspace.id, 7, "initial")
      end
    end
    assert_equal "🤖 No issues found 👍", fake.captured[:body]
    assert_empty fake.captured[:comments]
  end

  test "unparseable AI output does not advance the SHA" do
    fake = fake_github(pr: pr_payload(sha: "abc"))
    with_github(fake) do
      with_ai("not json at all") do
        PrReviewJob.perform_now(@workspace.id, 7, "initial")
      end
    end
    assert_nil PrReview.find_by(workspace: @workspace, pr_number: 7)
    assert_empty fake.captured
  end
end
