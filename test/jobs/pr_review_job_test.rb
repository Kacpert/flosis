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

  # Simulate the claude CLI failing to run (vs. running and returning prose).
  def with_ai_error
    orig = ClaudeCliService.instance_method(:start_session)
    ClaudeCliService.define_method(:start_session) { |**_kw| raise ClaudeCliService::ClaudeCliError, "boom" }
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

  test "persists PR metadata after fetch" do
    pr = pr_payload(sha: "abc").merge(
      "title" => "DEV-836 thing",
      "html_url" => "https://github.com/acme/widgets/pull/7",
      "user" => { "login" => "octocat" }
    )
    fake = fake_github(pr: pr)
    with_github(fake) do
      with_ai("[]") do
        PrReviewJob.perform_now(@workspace.id, 7, "initial")
      end
    end

    review = PrReview.find_by(workspace: @workspace, pr_number: 7)
    assert_equal "DEV-836 thing", review.pr_title
    assert_equal "octocat", review.pr_author
    assert_equal "dev-836-thing", review.pr_branch
    assert_equal "https://github.com/acme/widgets/pull/7", review.pr_url
  end

  test "sets outcome looks_good and comment_count 0 when no comments" do
    fake = fake_github(pr: pr_payload(sha: "abc"))
    with_github(fake) do
      with_ai("[]") do
        PrReviewJob.perform_now(@workspace.id, 7, "initial")
      end
    end

    review = PrReview.find_by(workspace: @workspace, pr_number: 7)
    assert_equal "looks_good", review.outcome
    assert_equal 0, review.comment_count
  end

  test "sets outcome comments and comment_count N when comments posted" do
    fake = fake_github(pr: pr_payload(sha: "abc"))
    ai = [ 1, 2, 3 ].map { |i| { "path" => "a.rb", "line" => i, "comment" => "c#{i}" } }.to_json

    with_github(fake) do
      with_ai(ai) do
        PrReviewJob.perform_now(@workspace.id, 7, "initial")
      end
    end

    review = PrReview.find_by(workspace: @workspace, pr_number: 7)
    assert_equal "comments", review.outcome
    assert_equal 3, review.comment_count
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

  test "prose verdict with no JSON array posts the no-issues review and marks reviewed" do
    # The AI ran fine and judged the PR sound, but emitted only prose (no array).
    # This must be treated as zero issues, NOT a failure to retry.
    fake = fake_github(pr: pr_payload(sha: "abc"))
    with_github(fake) do
      with_ai("The fix looks correct and minimal. I traced the callers and found no issues.") do
        PrReviewJob.perform_now(@workspace.id, 7, "initial")
      end
    end
    assert_equal "🤖 No issues found 👍", fake.captured[:body]
    review = PrReview.find_by(workspace: @workspace, pr_number: 7)
    assert_not_nil review, "a sound PR must be marked reviewed, not retried forever"
    assert_equal "abc", review.last_reviewed_sha
  end

  test "a genuine CLI error does NOT mark reviewed (retries next cycle)" do
    fake = fake_github(pr: pr_payload(sha: "abc"))
    with_github(fake) do
      with_ai_error do
        PrReviewJob.perform_now(@workspace.id, 7, "initial")
      end
    end
    assert_nil PrReview.find_by(workspace: @workspace, pr_number: 7), "CLI failure should not post or advance"
    assert_empty fake.captured
  end

  test "an auth-error response is NOT treated as no-issues (retries, posts nothing)" do
    # The CLI prints a 401 as plain text rather than raising; this must not be
    # mistaken for a clean review.
    fake = fake_github(pr: pr_payload(sha: "abc"))
    with_github(fake) do
      with_ai("Failed to authenticate. API Error: 401 Invalid authentication credentials") do
        PrReviewJob.perform_now(@workspace.id, 7, "initial")
      end
    end
    assert_nil PrReview.find_by(workspace: @workspace, pr_number: 7), "auth failure must not mark reviewed"
    assert_empty fake.captured, "auth failure must not post a review"
  end

  test "build_prompt uses DEFAULT_PROMPT when workspace.pr_review_prompt is blank" do
    @workspace.update!(pr_review_prompt: nil)
    job = PrReviewJob.new
    prompt = job.send(:build_prompt, @workspace, pr_payload, [ { "filename" => "a.rb", "patch" => "@@ -1 +1 @@\n+code" } ], "initial")

    assert_includes prompt, PrReviewJob::DEFAULT_PROMPT.split("\n").first
    assert_includes prompt, "senior engineer reviewing a GitHub pull request"
  end

  test "build_prompt uses workspace.pr_review_prompt when present, still interpolating dynamic context" do
    @workspace.update!(pr_review_prompt: "Custom persona: be extremely terse.")
    job = PrReviewJob.new
    files = [ { "filename" => "a.rb", "patch" => "@@ -1 +1 @@\n+code" } ]
    prompt = job.send(:build_prompt, @workspace, pr_payload, files, "initial")

    assert_includes prompt, "Custom persona: be extremely terse."
    refute_includes prompt, "senior engineer reviewing a GitHub pull request"
    # Dynamic interpolation (ticket context + diff + cap) must still work.
    assert_includes prompt, "No linked Jira ticket."
    assert_includes prompt, "FILE: a.rb"
    assert_includes prompt, "AT MOST 4 items"
  end
end
