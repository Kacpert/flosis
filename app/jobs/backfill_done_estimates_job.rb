# One-off backfill: estimate every DONE task in a project that doesn't yet have
# an AI estimate, then mirror the value into delivered_issues.ai_estimate_points
# so Reporting shows it. Runs entirely on the server (Solid Queue) so it survives
# a laptop being turned off, and PACES itself with a random 3–10s gap between
# tasks to avoid hammering the Claude CLI / rate limits over a long run.
#
# "Done" = a task whose Jira status is one of the finished board columns
# (JiraClient::DONE_STATUS_NAMES). Idempotent: skips tasks that already have an
# ai_estimate_points, so it can be safely re-run / resumed.
class BackfillDoneEstimatesJob < ApplicationJob
  queue_as :default

  MIN_GAP = 3
  MAX_GAP = 10

  def perform(project_id)
    project = Project.find_by(id: project_id)
    return unless project

    keys = done_jira_keys(project)
    tasks = project.tasks.jira_synced
                   .where(external_reference: keys)
                   .where(ai_estimate_points: nil)
                   .to_a

    Rails.logger.info("[BackfillDoneEstimates] project=#{project_id} candidates=#{tasks.size}")

    tasks.each_with_index do |task, i|
      begin
        # Force past the estimate-once guard (this is a deliberate backfill) and
        # run inline so we can pace between tasks and mirror the result.
        AutoEstimateJob.new.perform(task.id, force: true)
        mirror_to_delivered(project, task)
        Rails.logger.info("[BackfillDoneEstimates] #{i + 1}/#{tasks.size} #{task.external_reference} -> #{task.reload.ai_estimate_points.inspect}")
      rescue StandardError => e
        # One bad task must never kill a multi-hour backfill — log and move on.
        Rails.logger.error("[BackfillDoneEstimates] #{task.external_reference} failed: #{e.class}: #{e.message}")
      end

      # Random 3–10s pause between tasks (skip after the last one).
      sleep(rand(MIN_GAP..MAX_GAP)) unless i == tasks.size - 1
    end

    Rails.logger.info("[BackfillDoneEstimates] project=#{project_id} DONE")
  end

  private

  # Jira keys of the project's done issues (from the widened delivered set).
  def done_jira_keys(project)
    project.delivered_issues.pluck(:jira_key)
  end

  # Copy the task's fresh ai_estimate_points onto its matching delivered_issue so
  # Reporting (which reads delivered_issues) reflects it immediately.
  def mirror_to_delivered(project, task)
    pts = task.reload.ai_estimate_points
    return if pts.blank?

    di = project.delivered_issues.find_by(jira_key: task.external_reference)
    di&.update_column(:ai_estimate_points, pts)
  end
end
