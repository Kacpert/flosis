# One-off backfill: AI-estimate DELIVERED issues that have no matching Task
# (older done work that only lives in delivered_issues, e.g. pre-pipeline
# history). Scores each on the SAME 1–100 rubric as AutoEstimateJob, but built
# from the issue's Jira title + description (no brief). Runs in the checked-out
# repo so the AI can still ground its score in the code.
#
# Server-side (Solid Queue), self-paced with a random 3–10s gap, idempotent
# (skips issues already estimated), and resilient to per-issue failures.
#
# `model:` lets a big one-off run use a cheaper model (e.g. Haiku) — passed
# through to ClaudeCliService.
class BackfillDeliveredEstimatesJob < ApplicationJob
  queue_as :default

  CODEBASE_PATH = ENV.fetch("PR_REVIEW_CODEBASE_PATH", File.expand_path("~/work/elvium"))
  MIN_GAP = 3
  MAX_GAP = 10

  # Same CLI-failure detection as AutoEstimateJob (auth/quota printed as text).
  CLI_FAILURE_MARKERS = /\b(401|403|429|invalid authentication|failed to authenticate|api error|credit balance|rate limit|usage limit|overloaded|unauthorized)\b/i

  def perform(project_id, model: nil)
    project = Project.find_by(id: project_id)
    return unless project

    scope = project.delivered_issues
                   .where(ai_estimate_points: nil)
                   .where.not(description: [ nil, "" ])
    issues = scope.to_a
    Rails.logger.info("[BackfillDeliveredEstimates] project=#{project_id} candidates=#{issues.size} model=#{model.inspect}")

    issues.each_with_index do |di, i|
      begin
        score = estimate(di, model: model)
        if score
          di.update_column(:ai_estimate_points, (score / 2.0).round)
          Rails.logger.info("[BackfillDeliveredEstimates] #{i + 1}/#{issues.size} #{di.jira_key} score=#{score} -> #{di.ai_estimate_points}")
        else
          Rails.logger.info("[BackfillDeliveredEstimates] #{i + 1}/#{issues.size} #{di.jira_key} -> no estimate")
        end
      rescue StandardError => e
        Rails.logger.error("[BackfillDeliveredEstimates] #{di.jira_key} failed: #{e.class}: #{e.message}")
      end

      sleep(rand(MIN_GAP..MAX_GAP)) unless i == issues.size - 1
    end

    Rails.logger.info("[BackfillDeliveredEstimates] project=#{project_id} DONE")
  end

  private

  # Returns the raw 1–100 score for a delivered issue, or nil on failure.
  def estimate(di, model: nil)
    ticket = "Ticket #{di.jira_key}: #{di.title}\n#{di.description}"
    prompt = AutoEstimateJob.rubric_prompt(ticket)

    response = ClaudeCliService.new(codebase_path: CODEBASE_PATH, model: model)
                               .start_session(prompt: prompt)[:response].to_s
    return nil if response.match?(CLI_FAILURE_MARKERS) || response.strip.length < 20

    EstimateParser.extract(response)&.dig(:score)
  rescue ClaudeCliService::ClaudeCliError => e
    Rails.logger.error("[BackfillDeliveredEstimates] claude error on #{di.jira_key}: #{e.message}")
    nil
  end
end
