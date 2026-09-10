require "test_helper"

class PrReviewJobTest < ActiveJob::TestCase
  setup do
    @workspace = workspaces(:one)
    @workspace.update!(github_token: "t", github_repo: "acme/widgets", pr_review_enabled: true)
  end

  # `reviews` decides what create_review returns, call by call: [true] accepts
  # the first, [false, true] rejects the inline review and accepts the plain
  # retry, [false, false] rejects both. Every call is recorded in `attempts`.
  def fake_github(pr:, files: [ { "filename" => "a.rb", "patch" => "@@ -1 +1 @@\n+code" } ], commits: [],
                  existing_comments: [], reviews: [ true ])
    fake = Object.new
    captured = {}
    attempts = []
    results = reviews.dup
    fake.define_singleton_method(:pull_request) { |_n| pr }
    fake.define_singleton_method(:pull_request_files) { |_n| files }
    fake.define_singleton_method(:pull_request_commits) { |_n| commits }
    fake.define_singleton_method(:pull_request_review_comments) { |_n| existing_comments }
    fake.define_singleton_method(:create_review) do |n, body:, event:, comments:|
      captured.merge!(n: n, body: body, comments: comments)
      attempts << { body: body, comments: comments }
      results.empty? ? true : results.shift
    end
    fake.define_singleton_method(:configured?) { true }
    fake.define_singleton_method(:captured) { captured }
    fake.define_singleton_method(:attempts) { attempts }
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

  test "does NOT re-post a comment already present on the PR (dedup across pushes)" do
    PrReview.create!(workspace: @workspace, pr_number: 7, last_reviewed_sha: "old", initial_done: true)
    # The PR already has this exact comment from a previous review.
    existing = [ { "path" => "a.rb", "line" => 5, "body" => "Wire the toggle into both tabs." } ]
    fake = fake_github(pr: pr_payload(sha: "new"), commits: [ { "sha" => "new" } ], existing_comments: existing)
    # The AI re-flags the same issue (whole diff re-reviewed) plus a genuinely new one.
    ai = [
      { "path" => "a.rb", "line" => 9, "comment" => "Wire the toggle into both tabs." }, # duplicate (line shifted)
      { "path" => "a.rb", "line" => 12, "comment" => "A brand new issue." }
    ].to_json

    with_github(fake) do
      with_ai(ai) do
        PrReviewJob.perform_now(@workspace.id, 7, "followup")
      end
    end

    bodies = fake.captured[:comments].map { |c| c[:body] }
    assert_equal [ "A brand new issue." ], bodies, "must skip the already-posted comment, keep the new one"
  end

  test "when every issue was already posted, posts the no-issues review (no spam)" do
    PrReview.create!(workspace: @workspace, pr_number: 7, last_reviewed_sha: "old", initial_done: true)
    existing = [ { "path" => "a.rb", "line" => 5, "body" => "Same old comment." } ]
    fake = fake_github(pr: pr_payload(sha: "new"), commits: [ { "sha" => "new" } ], existing_comments: existing)
    ai = [ { "path" => "a.rb", "line" => 5, "comment" => "Same old comment." } ].to_json

    with_github(fake) do
      with_ai(ai) do
        PrReviewJob.perform_now(@workspace.id, 7, "followup")
      end
    end

    assert_empty fake.captured[:comments]
    assert_equal "🤖 No issues found 👍", fake.captured[:body]
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
    review = PrReview.find_by(workspace: @workspace, pr_number: 7)
    assert_nil review.reviewed_at, "CLI failure must not mark the PR reviewed"
    assert_nil review.last_reviewed_sha
    assert_empty fake.captured
    # The failure is recorded rather than erased: it costs one retry from the
    # budget and schedules the next attempt, so the next poll doesn't spend a
    # whole AI review again.
    assert_equal 1, review.attempts
    assert_equal "abc", review.attempt_sha
    assert_equal "error", review.outcome
    assert_nil review.enqueued_sha, "the claim is released so the retry can re-claim"
    assert review.last_error.present?
    assert review.next_attempt_at > Time.current
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
    review = PrReview.find_by(workspace: @workspace, pr_number: 7)
    assert_nil review.reviewed_at, "auth failure must not mark reviewed"
    assert_empty fake.captured, "auth failure must not post a review"
    assert_equal 1, review.attempts
    assert_match(/authenticate/i, review.last_error)
  end

  # GitHub rejects an inline comment whose line is not part of the diff, and
  # throws away the WHOLE review with it — 422. Four PRs (1214, 1233, 1268,
  # 1273) were recorded here as reviewed while nothing ever reached them.

  test "a rejected inline review is retried as a plain one carrying the findings" do
    fake = fake_github(pr: pr_payload(sha: "abc"), reviews: [ false, true ])

    with_github(fake) do
      with_ai(%([{"path": "app/models/user.rb", "line": 42, "comment": "This drops the transaction."}])) do
        PrReviewJob.perform_now(@workspace.id, 7, "initial")
      end
    end

    assert_equal 2, fake.attempts.size, "the inline attempt, then the fallback"
    assert fake.attempts.first[:comments].any?, "first attempt pins the finding to the diff"
    assert_empty fake.attempts.last[:comments], "the retry carries no inline comments"
    # The finding must survive the fallback, with where it was meant to point.
    assert_match(/app\/models\/user\.rb:42/, fake.attempts.last[:body])
    assert_match(/drops the transaction/, fake.attempts.last[:body])

    review = PrReview.find_by(workspace: @workspace, pr_number: 7)
    assert_equal "abc", review.last_reviewed_sha, "the fallback counts as posted"
    assert_equal "comments", review.outcome
  end

  test "a review GitHub refuses outright is not recorded as posted" do
    fake = fake_github(pr: pr_payload(sha: "abc"), reviews: [ false, false ])

    with_github(fake) do
      with_ai(%([{"path": "a.rb", "line": 1, "comment": "Something."}])) do
        PrReviewJob.perform_now(@workspace.id, 7, "initial")
      end
    end

    review = PrReview.find_by(workspace: @workspace, pr_number: 7)
    assert_nil review.reviewed_at, "nothing reached the PR, so it is not reviewed"
    assert_nil review.last_reviewed_sha
    assert_equal 1, review.attempts, "it costs a retry and comes back with a backoff"
    assert_match(/rejected/i, review.last_error)
  end

  test "a rejected no-issues review is not recorded as posted either" do
    fake = fake_github(pr: pr_payload(sha: "abc"), reviews: [ false ])

    with_github(fake) { with_ai("[]") { PrReviewJob.perform_now(@workspace.id, 7, "initial") } }

    assert_nil PrReview.find_by(workspace: @workspace, pr_number: 7).reviewed_at
  end

  test "a successful review clears the retry state left by earlier failures" do
    record = PrReview.create!(workspace: @workspace, pr_number: 7)
    record.record_failure!("abc", "Claude CLI not found")

    with_github(fake_github(pr: pr_payload(sha: "abc"))) do
      with_ai("[]") { PrReviewJob.perform_now(@workspace.id, 7, "initial") }
    end

    record.reload
    assert_equal "looks_good", record.outcome
    assert_equal 0, record.attempts
    assert_nil record.attempt_sha
    assert_nil record.last_error
    assert_nil record.next_attempt_at
  end

  # What a ticket ends up meaning is usually settled in its comments ("we agreed
  # to drop X", "admins only") — a reviewer without them flags decisions as
  # mistakes.
  test "the prompt carries the linked ticket's comments, oldest last" do
    task = tasks(:jira_task)
    task.update!(external_reference: "DEV-836", description: "Original description.")
    task.jira_comments.create!(jira_comment_id: "1", author_name: "Ana", body: "We agreed to drop the cache.",
                               jira_created_at: 3.days.ago)
    task.jira_comments.create!(jira_comment_id: "2", author_name: "Bo", body: "Admins only, not recruiters.",
                               jira_created_at: 1.day.ago)

    prompt = PrReviewJob.new.send(:build_prompt, @workspace, pr_payload, [], "initial")

    assert_includes prompt, "Linked Jira ticket DEV-836"
    assert_includes prompt, "Original description."
    assert_includes prompt, "Comments on the ticket"
    assert_includes prompt, "Ana"
    assert_includes prompt, "We agreed to drop the cache."
    assert_operator prompt.index("We agreed to drop the cache."), :<,
                    prompt.index("Admins only, not recruiters."), "oldest first, newest last"
  end

  test "only the most recent comments travel, and the prompt says so" do
    task = tasks(:jira_task)
    task.update!(external_reference: "DEV-836")
    (PrReviewJob::MAX_TICKET_COMMENTS + 3).times do |i|
      task.jira_comments.create!(jira_comment_id: "c#{i}", author_name: "Ana",
                                 body: "comment number #{i}", jira_created_at: (30 - i).days.ago)
    end

    prompt = PrReviewJob.new.send(:build_prompt, @workspace, pr_payload, [], "initial")

    assert_includes prompt, "the #{PrReviewJob::MAX_TICKET_COMMENTS} most recent of #{PrReviewJob::MAX_TICKET_COMMENTS + 3}"
    assert_not_includes prompt, "comment number 0", "the oldest are dropped"
    assert_includes prompt, "comment number #{PrReviewJob::MAX_TICKET_COMMENTS + 2}", "the newest is kept"
  end

  test "a ticket with no comments reads exactly as before" do
    tasks(:jira_task).update!(external_reference: "DEV-836")

    prompt = PrReviewJob.new.send(:build_prompt, @workspace, pr_payload, [], "initial")

    assert_includes prompt, "Linked Jira ticket DEV-836"
    assert_not_includes prompt, "Comments on the ticket"
  end

  # The reviewer gets read-only Jira: a PR names its ticket, and the epic or a
  # linked issue is often what separates "this is wrong" from "this is what was
  # asked for". It must never be able to write.
  test "the review tool set adds read-only Jira and nothing that writes" do
    tools = ClaudeCliService::REVIEW_TOOLS

    assert_includes tools, "mcp__jira__jira_get_issue"
    assert_includes tools, "mcp__jira__jira_search"
    assert_includes tools, "Read", "and keeps the codebase tools"
    %w[jira_add_comment jira_edit_comment jira_update_issue jira_transition_issue jira_create_issue
       jira_delete_issue].each do |tool|
      assert_not_includes tools, "mcp__jira__#{tool}"
    end
    assert_not_includes tools, "Bash"
  end

  test "build_prompt with blank pr_review_prompt preserves the original ticket/diff/instructions ORDER" do
    @workspace.update!(pr_review_prompt: nil)
    job = PrReviewJob.new
    prompt = job.send(:build_prompt, @workspace, pr_payload, [ { "filename" => "a.rb", "patch" => "@@ -1 +1 @@\n+code" } ], "initial")

    assert_includes prompt, "senior engineer reviewing a GitHub pull request"
    # The pre-9.1 monolithic prompt interleaved the ticket + diff BETWEEN the
    # persona and the INVESTIGATE steps. The token-based template must keep that
    # exact order (regression guard for the DEFAULT_PROMPT extraction).
    ticket_idx = prompt.index("No linked Jira ticket.")
    diff_idx = prompt.index("Changed files and diffs:")
    investigate_idx = prompt.index("Before writing anything, INVESTIGATE")
    json_idx = prompt.index(%q({"path":))
    assert ticket_idx < diff_idx, "ticket must come before the diff"
    assert diff_idx < investigate_idx, "diff must come before the INVESTIGATE instructions"
    assert investigate_idx < json_idx, "JSON tail must come last"
    # No leftover template tokens, and no doubled-blank-line seam.
    refute_includes prompt, "{{", "all substitution tokens must be replaced"
    refute_includes prompt, "\n\n\n", "must not introduce a doubled blank line"
    assert_includes prompt, "AT MOST 4 items"
  end

  test "build_prompt uses workspace.pr_review_prompt (with tokens) when present, still interpolating context" do
    @workspace.update!(pr_review_prompt: "Custom persona: be extremely terse.\n\n{{TICKET}}\n\n{{DIFF}}\n\nAT MOST {{CAP}} items.")
    job = PrReviewJob.new
    files = [ { "filename" => "a.rb", "patch" => "@@ -1 +1 @@\n+code" } ]
    prompt = job.send(:build_prompt, @workspace, pr_payload, files, "initial")

    assert_includes prompt, "Custom persona: be extremely terse."
    refute_includes prompt, "senior engineer reviewing a GitHub pull request"
    # Dynamic token substitution (ticket context + diff + cap) still works for a custom prompt.
    assert_includes prompt, "No linked Jira ticket."
    assert_includes prompt, "FILE: a.rb"
    assert_includes prompt, "AT MOST 4 items"
    refute_includes prompt, "{{"
  end
end
