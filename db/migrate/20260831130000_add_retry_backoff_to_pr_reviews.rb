# A failed AI review used to leave no trace: PrReviewJob deleted the claim (or
# cleared enqueued_sha) so the very next PrReviewCheckJob treated the PR as new
# and ran a FULL Claude review again — every ~7 minutes, forever. Production
# had PR #1205 re-reviewed 212 times and #1261 196 times.
#
# These columns give a failure a memory: how many times we've tried THIS head
# SHA, when the next attempt is allowed, and what went wrong (surfaced in the
# AI PR Reviews tab). PrReviewCheckJob honours them; new commits (a new SHA)
# reset the counter.
class AddRetryBackoffToPrReviews < ActiveRecord::Migration[8.1]
  def change
    add_column :pr_reviews, :attempts, :integer, default: 0, null: false
    add_column :pr_reviews, :attempt_sha, :string
    add_column :pr_reviews, :last_error, :string
    add_column :pr_reviews, :next_attempt_at, :datetime
  end
end
