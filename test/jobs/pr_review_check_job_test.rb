require "test_helper"

class PrReviewCheckJobTest < ActiveJob::TestCase
  setup do
    @workspace = workspaces(:one)
    @workspace.update!(github_token: "t", github_repo: "acme/widgets", pr_review_enabled: true)
  end

  def fake_github(prs:, health: { ok: true })
    fake = Object.new
    fake.define_singleton_method(:configured?) { true }
    fake.define_singleton_method(:health_check) { health }
    fake.define_singleton_method(:open_pull_requests) { prs }
    fake.define_singleton_method(:pull_request) { |n| prs.find { |p| p["number"] == n } }
    fake
  end

  def with_github(fake)
    orig = GithubClient.method(:for)
    GithubClient.define_singleton_method(:for) { |*_a, **_k| fake }
    yield
  ensure
    GithubClient.define_singleton_method(:for, orig)
  end

  def pr(number, sha, draft: false)
    { "number" => number, "draft" => draft, "head" => { "sha" => sha } }
  end

  test "enqueues initial review for an unseen PR and claims it" do
    travel_to Time.zone.local(2026, 6, 15, 10, 0) do
      fake = fake_github(prs: [ pr(7, "abc") ])
      with_github(fake) do
        assert_enqueued_with(job: PrReviewJob, args: [ @workspace.id, 7, "initial" ]) do
          PrReviewCheckJob.perform_now
        end
      end
    end
    claim = PrReview.find_by(workspace: @workspace, pr_number: 7)
    assert_equal "abc", claim.enqueued_sha
    assert_nil claim.reviewed_at, "claim is not yet reviewed"
  end

  test "a second check does not double-enqueue an already-claimed PR" do
    travel_to Time.zone.local(2026, 6, 15, 10, 0) do
      fake = fake_github(prs: [ pr(7, "abc") ])
      with_github(fake) { PrReviewCheckJob.perform_now } # claims it
      with_github(fake) do
        assert_no_enqueued_jobs(only: PrReviewJob) { PrReviewCheckJob.perform_now }
      end
    end
    assert_equal 1, PrReview.where(workspace: @workspace, pr_number: 7).count
  end

  test "enqueues followup when head SHA changed" do
    PrReview.create!(workspace: @workspace, pr_number: 7, last_reviewed_sha: "old", initial_done: true, reviewed_at: Time.current)
    travel_to Time.zone.local(2026, 6, 15, 10, 0) do
      fake = fake_github(prs: [ pr(7, "new") ])
      with_github(fake) do
        assert_enqueued_with(job: PrReviewJob, args: [ @workspace.id, 7, "followup" ]) do
          PrReviewCheckJob.perform_now
        end
      end
    end
  end

  test "skips unchanged PR" do
    PrReview.create!(workspace: @workspace, pr_number: 7, last_reviewed_sha: "same", initial_done: true)
    travel_to Time.zone.local(2026, 6, 15, 10, 0) do
      with_github(fake_github(prs: [ pr(7, "same") ])) do
        assert_no_enqueued_jobs(only: PrReviewJob) { PrReviewCheckJob.perform_now }
      end
    end
  end

  test "skips drafts" do
    travel_to Time.zone.local(2026, 6, 15, 10, 0) do
      with_github(fake_github(prs: [ pr(7, "abc", draft: true) ])) do
        assert_no_enqueued_jobs(only: PrReviewJob) { PrReviewCheckJob.perform_now }
      end
    end
  end

  test "skips scan and records failure when health check fails" do
    travel_to Time.zone.local(2026, 6, 15, 10, 0) do
      with_github(fake_github(prs: [ pr(7, "abc") ], health: { ok: false, error: "401 Unauthorized" })) do
        assert_no_enqueued_jobs(only: PrReviewJob) { PrReviewCheckJob.perform_now }
      end
    end
    @workspace.reload
    assert_not @workspace.github_status_ok
    assert_equal "401 Unauthorized", @workspace.github_status_error
  end

  test "records healthy status" do
    travel_to Time.zone.local(2026, 6, 15, 10, 0) do
      with_github(fake_github(prs: [])) { PrReviewCheckJob.perform_now }
    end
    assert @workspace.reload.github_status_ok
  end

  test "stamps pr_polled_at on each poll" do
    travel_to Time.zone.local(2026, 6, 15, 10, 0) do
      with_github(fake_github(prs: [])) { PrReviewCheckJob.perform_now }
    end
    assert_equal Time.zone.local(2026, 6, 15, 10, 0), @workspace.reload.pr_polled_at
  end

  test "skips a workspace polled less than max(7, pr_poll_minutes) minutes ago" do
    travel_to Time.zone.local(2026, 6, 15, 10, 0) do
      @workspace.update!(pr_poll_minutes: 5, pr_polled_at: 2.minutes.ago)
      with_github(fake_github(prs: [ pr(7, "abc") ])) do
        assert_no_enqueued_jobs(only: PrReviewJob) { PrReviewCheckJob.perform_now }
      end
    end
  end

  test "polls a workspace whose pr_polled_at is nil" do
    @workspace.update!(pr_polled_at: nil)
    travel_to Time.zone.local(2026, 6, 15, 10, 0) do
      with_github(fake_github(prs: [ pr(7, "abc") ])) do
        assert_enqueued_with(job: PrReviewJob, args: [ @workspace.id, 7, "initial" ]) do
          PrReviewCheckJob.perform_now
        end
      end
    end
  end

  test "polls a workspace whose pr_polled_at is older than the effective interval" do
    travel_to Time.zone.local(2026, 6, 15, 10, 0) do
      @workspace.update!(pr_poll_minutes: 3, pr_polled_at: 8.minutes.ago)
      with_github(fake_github(prs: [ pr(7, "abc") ])) do
        assert_enqueued_with(job: PrReviewJob, args: [ @workspace.id, 7, "initial" ]) do
          PrReviewCheckJob.perform_now
        end
      end
    end
  end

  # ---- retry budget ------------------------------------------------------
  # Regression: a failed review used to release its claim, so the very next poll
  # ran a full (token-burning) AI review again — production hit 212 reviews on
  # one PR. A failure now costs a bounded number of retries per head SHA.

  test "does not re-enqueue a failed review while its backoff is still running" do
    record = PrReview.create!(workspace: @workspace, pr_number: 7)
    travel_to(Time.zone.local(2026, 6, 15, 10, 0)) { record.record_failure!("abc", "Claude CLI not found") }

    travel_to Time.zone.local(2026, 6, 15, 10, 10) do
      with_github(fake_github(prs: [ pr(7, "abc") ])) do
        assert_no_enqueued_jobs(only: PrReviewJob) { PrReviewCheckJob.perform_now }
      end
    end
  end

  test "retries a failed review once its backoff has elapsed" do
    record = PrReview.create!(workspace: @workspace, pr_number: 7)
    travel_to(Time.zone.local(2026, 6, 15, 10, 0)) { record.record_failure!("abc", "Claude CLI not found") }

    travel_to Time.zone.local(2026, 6, 15, 10, 20) do
      with_github(fake_github(prs: [ pr(7, "abc") ])) do
        assert_enqueued_with(job: PrReviewJob, args: [ @workspace.id, 7, "initial" ]) do
          PrReviewCheckJob.perform_now
        end
      end
    end
    assert_equal "abc", record.reload.enqueued_sha, "the retry re-claims the SHA"
  end

  test "stops retrying the same SHA after the attempt budget is spent" do
    record = PrReview.create!(workspace: @workspace, pr_number: 7)
    PrReview::MAX_ATTEMPTS.times { record.record_failure!("abc", "boom") }

    travel_to Time.zone.local(2026, 6, 20, 10, 0) do # far past every backoff
      with_github(fake_github(prs: [ pr(7, "abc") ])) do
        assert_no_enqueued_jobs(only: PrReviewJob) { PrReviewCheckJob.perform_now }
      end
    end
  end

  test "new commits revive a PR that had exhausted its retries" do
    record = PrReview.create!(workspace: @workspace, pr_number: 7)
    PrReview::MAX_ATTEMPTS.times { record.record_failure!("abc", "boom") }

    travel_to Time.zone.local(2026, 6, 20, 10, 0) do
      with_github(fake_github(prs: [ pr(7, "def") ])) do
        assert_enqueued_with(job: PrReviewJob, args: [ @workspace.id, 7, "initial" ]) do
          PrReviewCheckJob.perform_now
        end
      end
    end
  end

  test "a failed followup keeps the earlier review and retries as a followup" do
    record = PrReview.create!(workspace: @workspace, pr_number: 7, last_reviewed_sha: "old",
                              initial_done: true, reviewed_at: Time.current, outcome: "comments")
    travel_to(Time.zone.local(2026, 6, 15, 10, 0)) { record.record_failure!("new", "boom") }

    assert_equal "comments", record.reload.outcome, "a completed review is not overwritten by a later failure"

    travel_to Time.zone.local(2026, 6, 15, 10, 20) do
      with_github(fake_github(prs: [ pr(7, "new") ])) do
        assert_enqueued_with(job: PrReviewJob, args: [ @workspace.id, 7, "followup" ]) do
          PrReviewCheckJob.perform_now
        end
      end
    end
  end

  test "re-claims a PR whose review job died mid-flight (stale claim)" do
    travel_to(Time.zone.local(2026, 6, 15, 7, 0)) do
      PrReview.create!(workspace: @workspace, pr_number: 7, enqueued_sha: "abc")
    end

    travel_to Time.zone.local(2026, 6, 15, 10, 0) do
      with_github(fake_github(prs: [ pr(7, "abc") ])) do
        assert_enqueued_with(job: PrReviewJob, args: [ @workspace.id, 7, "initial" ]) do
          PrReviewCheckJob.perform_now
        end
      end
    end
  end

  test "no-op outside working hours" do
    travel_to Time.zone.local(2026, 6, 15, 21, 0) do
      with_github(fake_github(prs: [ pr(7, "abc") ])) do
        assert_no_enqueued_jobs(only: PrReviewJob) { PrReviewCheckJob.perform_now }
      end
    end
  end

  test "no-op when disabled" do
    @workspace.update!(pr_review_enabled: false)
    travel_to Time.zone.local(2026, 6, 15, 10, 0) do
      with_github(fake_github(prs: [ pr(7, "abc") ])) do
        assert_no_enqueued_jobs(only: PrReviewJob) { PrReviewCheckJob.perform_now }
      end
    end
  end
end
