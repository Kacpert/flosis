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
          PrReviewJob.perform_later(workspace.id, number, "initial")
        elsif record.last_reviewed_sha != head_sha
          PrReviewJob.perform_later(workspace.id, number, "followup")
        end
      end
    end
  end
end
