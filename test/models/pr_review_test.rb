require "test_helper"

class PrReviewTest < ActiveSupport::TestCase
  test "valid with workspace and pr_number" do
    r = PrReview.new(workspace: workspaces(:one), pr_number: 7)
    assert r.valid?
  end

  test "pr_number unique per workspace" do
    PrReview.create!(workspace: workspaces(:one), pr_number: 7)
    dup = PrReview.new(workspace: workspaces(:one), pr_number: 7)
    assert_not dup.valid?
  end

  # ---- retry budget ------------------------------------------------------

  test "each failure on the same SHA counts up and waits longer" do
    r = PrReview.create!(workspace: workspaces(:one), pr_number: 7)
    now = Time.zone.local(2026, 6, 15, 10, 0)

    r.record_failure!("abc", "boom", now)
    assert_equal 1, r.attempts
    assert_equal now + PrReview::BACKOFF[0], r.next_attempt_at

    r.record_failure!("abc", "boom", now)
    assert_equal 2, r.attempts
    assert_equal now + PrReview::BACKOFF[1], r.next_attempt_at
  end

  test "a failure on a new SHA starts a fresh budget" do
    r = PrReview.create!(workspace: workspaces(:one), pr_number: 7)
    2.times { r.record_failure!("abc", "boom") }
    r.record_failure!("def", "boom")

    assert_equal 1, r.attempts
    assert_equal "def", r.attempt_sha
  end

  test "retry_allowed? gates on the backoff and then on the budget" do
    r = PrReview.create!(workspace: workspaces(:one), pr_number: 7)
    now = Time.zone.local(2026, 6, 15, 10, 0)
    r.record_failure!("abc", "boom", now)

    assert_not r.retry_allowed?("abc", now + 5.minutes), "still cooling down"
    assert r.retry_allowed?("abc", now + 20.minutes), "backoff elapsed"
    assert r.retry_allowed?("def", now), "a new SHA is never blocked"

    (PrReview::MAX_ATTEMPTS - 1).times { r.record_failure!("abc", "boom", now) }
    assert_not r.retry_allowed?("abc", now + 1.year), "budget spent — only new commits revive it"
    assert r.retries_exhausted?
  end

  test "a completed review keeps its outcome when a later attempt fails" do
    r = PrReview.create!(workspace: workspaces(:one), pr_number: 7,
                         outcome: "comments", reviewed_at: Time.current)
    r.record_failure!("abc", "boom")

    assert_equal "comments", r.outcome
  end

  test "claimed? ignores a claim older than CLAIM_TIMEOUT" do
    now = Time.zone.local(2026, 6, 15, 10, 0)
    r = PrReview.create!(workspace: workspaces(:one), pr_number: 7, enqueued_sha: "abc")

    assert r.claimed?("abc", r.updated_at + 5.minutes)
    assert_not r.claimed?("abc", r.updated_at + PrReview::CLAIM_TIMEOUT + 1.minute)
    assert_not r.claimed?("def", now), "a claim on another SHA doesn't block"
  end
end
