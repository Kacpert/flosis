class PrReviewCheckJob < ApplicationJob
  queue_as :default

  WINDOW = (9...20) # 09:00–19:59 local

  def perform
    return unless WINDOW.cover?(Time.current.hour)

    Workspace.where(pr_review_enabled: true).find_each do |workspace|
      github = GithubClient.for(workspace)
      next unless github.configured?

      health = github.health_check
      workspace.update_columns(
        github_status_ok: health[:ok],
        github_status_error: health[:error],
        github_status_checked_at: Time.current
      )
      next unless health[:ok]

      github.open_pull_requests.each do |pr|
        next if pr["draft"]
        number = pr["number"]
        head_sha = pr.dig("head", "sha")
        record = PrReview.find_by(workspace_id: workspace.id, pr_number: number)

        if record.nil?
          # Atomically CLAIM the PR by inserting its row first. The unique
          # [workspace_id, pr_number] index means a concurrent check (or a manual
          # run) loses the race and is skipped, so we never post two initial
          # reviews for the same PR. enqueued_sha records what we're reviewing.
          begin
            PrReview.create!(workspace_id: workspace.id, pr_number: number, enqueued_sha: head_sha)
          rescue ActiveRecord::RecordNotUnique
            next
          end
          PrReviewJob.perform_later(workspace.id, number, "initial")
        elsif record.reviewed_at.present? && record.last_reviewed_sha != head_sha && record.enqueued_sha != head_sha
          # New commits since the last completed review, and not already claimed
          # for this SHA → claim this SHA and enqueue a followup.
          record.update!(enqueued_sha: head_sha)
          PrReviewJob.perform_later(workspace.id, number, "followup")
        end
      end
    end
  end
end
