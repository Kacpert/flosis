# The cheap half of the PR reviewer: a plain GitHub REST poll (no AI at all)
# that decides which PRs are worth spending an AI review on. It enqueues
# PrReviewJob — the expensive half — ONLY for a PR we've never reviewed or one
# whose head SHA moved since the last completed review.
#
# A failed review is retried at most PrReview::MAX_ATTEMPTS times per head SHA,
# with a growing delay (PrReview::BACKOFF). Before that budget existed, every
# failure released the claim and the next poll ran a full Claude review again —
# production burned 212 reviews on a single PR that way.
class PrReviewCheckJob < ApplicationJob
  queue_as :default

  WINDOW = (9...20) # 09:00–19:59 local

  def perform
    return unless WINDOW.cover?(Time.current.hour)

    Workspace.where(pr_review_enabled: true).find_each do |workspace|
      next unless due?(workspace)

      github = GithubClient.for(workspace)
      next unless github.configured?

      health = github.health_check
      workspace.update_columns(
        github_status_ok: health[:ok],
        github_status_error: health[:error],
        github_status_checked_at: Time.current,
        pr_polled_at: Time.current
      )
      next unless health[:ok]

      github.open_pull_requests.each do |pr|
        next if pr["draft"]
        check_pull_request(workspace, pr)
      end
    end
  end

  private

  def check_pull_request(workspace, pr)
    number = pr["number"]
    head_sha = pr.dig("head", "sha")
    record = PrReview.find_by(workspace_id: workspace.id, pr_number: number)

    return claim_new(workspace, number, head_sha) if record.nil?

    # Already being reviewed right now, or out of retries / still cooling down
    # after a failure on this exact SHA → spend nothing.
    return if record.claimed?(head_sha)
    return unless record.retry_allowed?(head_sha)

    if record.reviewed_at.nil? && record.last_reviewed_sha.blank?
      # Never completed a review: either a failed initial attempt whose backoff
      # has elapsed, or a claim whose worker died. Retry as an initial review.
      record.update!(enqueued_sha: head_sha)
      PrReviewJob.perform_later(workspace.id, number, "initial")
    elsif record.last_reviewed_sha != head_sha
      # New commits since the last completed review → claim this SHA and
      # enqueue a followup.
      record.update!(enqueued_sha: head_sha)
      PrReviewJob.perform_later(workspace.id, number, "followup")
    end
  end

  # Atomically CLAIM an unseen PR by inserting its row first. The unique
  # [workspace_id, pr_number] index means a concurrent check (or a manual run)
  # loses the race and is skipped, so we never post two initial reviews for the
  # same PR. enqueued_sha records what we're reviewing.
  def claim_new(workspace, number, head_sha)
    PrReview.create!(workspace_id: workspace.id, pr_number: number, enqueued_sha: head_sha)
    PrReviewJob.perform_later(workspace.id, number, "initial")
  rescue ActiveRecord::RecordNotUnique
    nil
  end

  # Effective poll interval is max(7, workspace.pr_poll_minutes) — 7 minutes is
  # the cron floor (this job itself only runs every ~7 min), so a smaller
  # setting can't make us poll more often than the cron actually fires.
  def due?(workspace)
    return true if workspace.pr_polled_at.nil?

    interval = [ 7, workspace.pr_poll_minutes ].max.minutes
    workspace.pr_polled_at <= Time.current - interval
  end
end
