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

  test "enqueues initial review for an unseen PR" do
    travel_to Time.zone.local(2026, 6, 15, 10, 0) do
      fake = fake_github(prs: [ pr(7, "abc") ])
      with_github(fake) do
        assert_enqueued_with(job: PrReviewJob, args: [ @workspace.id, 7, "initial" ]) do
          PrReviewCheckJob.perform_now
        end
      end
    end
  end

  test "enqueues followup when head SHA changed" do
    PrReview.create!(workspace: @workspace, pr_number: 7, last_reviewed_sha: "old", initial_done: true)
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
