class PrReview < ApplicationRecord
  belongs_to :workspace

  validates :pr_number, presence: true, uniqueness: { scope: :workspace_id }

  # ---- retry budget -----------------------------------------------------
  # Every AI review costs real tokens, so a review that fails is retried a
  # bounded number of times with a growing delay, and only for the SHA it
  # failed on. New commits (a new head SHA) are a fresh problem and get a fresh
  # budget. Without this, PrReviewCheckJob re-ran a full Claude review on the
  # same PR every poll — 212 times on one production PR.
  MAX_ATTEMPTS = 3
  BACKOFF = [ 15.minutes, 1.hour, 4.hours ].freeze

  # A claim (enqueued_sha set, job not finished) older than this is treated as
  # dead — the worker was restarted mid-review — so the PR isn't stuck unreviewed
  # forever. Well above the few minutes a real review takes.
  CLAIM_TIMEOUT = 1.hour

  # May we spend an AI review on this head SHA right now? False while the
  # backoff is still running and once the attempt budget for this SHA is spent
  # (then only new commits revive it).
  def retry_allowed?(head_sha, now = Time.current)
    return true if attempt_sha.blank? || attempt_sha != head_sha
    return false if attempts >= MAX_ATTEMPTS
    next_attempt_at.nil? || next_attempt_at <= now
  end

  # True while another run holds the claim on this SHA. A claim that outlived
  # CLAIM_TIMEOUT is stale (dead worker) and no longer blocks.
  def claimed?(head_sha, now = Time.current)
    return false if enqueued_sha.blank? || enqueued_sha != head_sha
    updated_at > now - CLAIM_TIMEOUT
  end

  # Record a failed review attempt against `head_sha` and schedule the next one.
  # The claim is released so the retry can re-claim, but `attempts` /
  # `next_attempt_at` keep the retry bounded. A PR that was reviewed before
  # keeps its previous outcome — only a never-reviewed one shows as errored.
  def record_failure!(head_sha, reason, now = Time.current)
    count = attempt_sha == head_sha ? attempts + 1 : 1
    delay = BACKOFF[[ count - 1, BACKOFF.size - 1 ].min]

    attrs = {
      enqueued_sha: nil,
      attempts: count,
      attempt_sha: head_sha,
      last_error: reason.to_s.truncate(240),
      next_attempt_at: now + delay
    }
    attrs[:outcome] = "error" if reviewed_at.nil?
    update!(attrs)
  end

  # Clear the retry state after a review completes — the next failure starts
  # from a full budget.
  def failure_cleared_attributes
    { attempts: 0, attempt_sha: nil, last_error: nil, next_attempt_at: nil }
  end

  # Has this PR used up its retry budget on the SHA it last failed at?
  def retries_exhausted?
    attempts >= MAX_ATTEMPTS && attempt_sha.present?
  end
end
