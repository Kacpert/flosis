# The cheap half of the PR reviewer: a plain GitHub REST poll (no AI at all)
# that decides which PRs are worth spending an AI review on. It enqueues
# PrReviewJob — the expensive half — ONLY for a PR we've never reviewed or one
# whose head SHA moved since the last completed review.
#
# A failed review is retried at most PrReview::MAX_ATTEMPTS times per head SHA,
# with a growing delay (PrReview::BACKOFF). Before that budget existed, every
# failure released the claim and the next poll ran a full Claude review again —
# production burned 212 reviews on a single PR that way.
#
# The repo, the token and the poll interval are the project's, and so is the
# PrReview row: two projects in one workspace can each have a PR number 7.
class PrReviewCheckJob < ApplicationJob
  queue_as :default

  WINDOW = (9...20) # 09:00–19:59 local

  # The cron floor: this job itself only fires every ~7 minutes, so a smaller
  # per-project setting cannot make us poll more often. Public because the
  # Process page has to promise the interval we will actually honour.
  POLL_FLOOR_MINUTES = 7

  # The interval a project is really polled at, whatever its slider says.
  def self.effective_poll_minutes(project)
    [ POLL_FLOOR_MINUTES, project&.pr_poll_minutes.to_i ].max
  end

  # Whether PRs are checked at this hour. Public for the same reason: outside
  # WINDOW the Process page says the poller is paused instead of promising a
  # poll that won't come until morning.
  def self.polling_now?(time = Time.current)
    WINDOW.cover?(time.hour)
  end

  def perform
    return unless self.class.polling_now?

    Project.active.where(pr_review_enabled: true).find_each do |project|
      next unless due?(project)

      github = GithubClient.for_project(project)
      next unless github.configured?

      health = github.health_check
      project.update_columns(
        github_status_ok: health[:ok],
        github_status_error: health[:error],
        github_status_checked_at: Time.current,
        pr_polled_at: Time.current
      )
      next unless health[:ok]

      github.open_pull_requests.each do |pr|
        next if pr["draft"]
        check_pull_request(project, pr)
      end
    rescue StandardError => e
      # One project's broken repository must not stop the rest from being
      # polled: without this the sweep dies on the first failure and every
      # project after it goes unpolled for as long as the failure lasts.
      Rails.logger.error("[PrReviewCheckJob] project #{project.id} failed: #{e.message}")
    end
  end

  private

  def check_pull_request(project, pr)
    number = pr["number"]
    head_sha = pr.dig("head", "sha")
    record = PrReview.find_by(project_id: project.id, pr_number: number)

    return claim_new(project, number, head_sha) if record.nil?

    # Already being reviewed right now, or out of retries / still cooling down
    # after a failure on this exact SHA → spend nothing.
    return if record.claimed?(head_sha)
    return unless record.retry_allowed?(head_sha)

    if record.reviewed_at.nil? && record.last_reviewed_sha.blank?
      # Never completed a review: either a failed initial attempt whose backoff
      # has elapsed, or a claim whose worker died. Retry as an initial review.
      record.update!(enqueued_sha: head_sha)
      PrReviewJob.perform_later(project.id, number, "initial")
    elsif record.last_reviewed_sha != head_sha
      # New commits since the last completed review → claim this SHA and
      # enqueue a followup.
      record.update!(enqueued_sha: head_sha)
      PrReviewJob.perform_later(project.id, number, "followup")
    end
  end

  # Atomically CLAIM an unseen PR by inserting its row first. The unique
  # [project_id, pr_number] index means a concurrent check (or a manual run)
  # loses the race and is skipped, so we never post two initial reviews for the
  # same PR. enqueued_sha records what we're reviewing.
  def claim_new(project, number, head_sha)
    PrReview.create!(project_id: project.id, workspace_id: project.workspace_id,
                     pr_number: number, enqueued_sha: head_sha)
    PrReviewJob.perform_later(project.id, number, "initial")
  rescue ActiveRecord::RecordNotUnique
    nil
  end

  def due?(project)
    return true if project.pr_polled_at.nil?

    project.pr_polled_at <= Time.current - self.class.effective_poll_minutes(project).minutes
  end
end
