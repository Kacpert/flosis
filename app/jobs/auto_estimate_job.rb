# Produces an AI story-point estimate for a task via the Claude CLI and
# writes it to every Jira field configured on the workspace
# (workspace.estimation_field_names) — and NEVER any field outside that list.
#
# Triggered by (workspace.estimation_trigger):
#   sprint   — JiraSyncService#sync_sprint_assignments, when a task newly
#              gains a sprint_id on a non-design board sprint
#   status   — JiraSyncService#sync_issues, when jira_status_name transitions
#              into workspace.estimation_status_trigger
#   briefed  — BriefCommitsController#commit, on a successful Jira write
#   manual   — the "Estimate" button (Workshop::IdeasController#estimate)
class AutoEstimateJob < ApplicationJob
  queue_as :default

  CODEBASE_PATH = ENV.fetch("PR_REVIEW_CODEBASE_PATH", File.expand_path("~/work/elvium"))

  # Same idea as PrReviewJob::CLI_FAILURE_MARKERS: the Claude CLI prints
  # auth/quota/transport failures as plain text instead of raising, so a
  # failure must not be mistaken for "no estimate" and silently dropped vs.
  # retried, nor (worse) mistaken for a real number.
  CLI_FAILURE_MARKERS = /\b(401|403|429|invalid authentication|failed to authenticate|api error|credit balance|rate limit|usage limit|overloaded|unauthorized)\b/i

  def perform(task_id)
    task = Task.find_by(id: task_id)
    return unless task

    return if skip?(task)

    workspace = task.project.workspace
    response = run_ai(task)
    return if response.nil? # CLI failed to run — do not save, do not crash

    estimate = EstimateParser.extract(response)
    return if estimate.nil? # garbage / no block / non-Fibonacci — no estimate this run

    task.update!(ai_estimate_points: estimate[:points], ai_estimated_at: Time.current)
    write_to_jira(task, workspace, estimate[:points])
  end

  private

  # Skip when the task already has an estimate that is still fresh relative
  # to Jira — i.e. jira_updated_at hasn't moved since we last estimated it.
  def skip?(task)
    return false if task.ai_estimate_points.blank?
    return false if task.ai_estimated_at.blank?
    return false if task.jira_updated_at.blank?

    task.jira_updated_at <= task.ai_estimated_at
  end

  def run_ai(task)
    prompt = build_prompt(task)
    ClaudeCliService.new(codebase_path: CODEBASE_PATH).start_session(prompt: prompt)[:response].to_s.tap do |response|
      return nil if cli_failed?(response)
    end
  rescue ClaudeCliService::ClaudeCliError => e
    Rails.logger.error("[AutoEstimateJob] claude error: #{e.message}")
    nil
  end

  def cli_failed?(response)
    response.match?(CLI_FAILURE_MARKERS) || response.strip.length < 20
  end

  def write_to_jira(task, workspace, points)
    return if task.external_reference.blank?

    client = JiraClient.new
    Array(workspace.estimation_field_names).each do |field_name|
      field_id = field_id_for(workspace, client, field_name)
      next if field_id.blank?

      client.set_number_field(issue_key: task.external_reference, field_id: field_id, value: points)
    end
  end

  # Resolves + caches the Jira custom field id for the given field name.
  # The workspace has a single cache column (jira_ai_estimation_field_id) for
  # the primary/default "AI estimation" field, mirroring
  # JiraWriter#ai_actions_field_id's caching pattern; any additional
  # configured field names are resolved fresh each run (still cheap — a
  # single GET /field call).
  def field_id_for(workspace, client, field_name)
    if field_name == Workspace::DEFAULT_ESTIMATION_FIELD_NAME
      return workspace.jira_ai_estimation_field_id if workspace.jira_ai_estimation_field_id.present?

      id = client.fetch_field_id(field_name)
      workspace.update_column(:jira_ai_estimation_field_id, id) if id.present?
      return id
    end

    client.fetch_field_id(field_name)
  end

  def build_prompt(task)
    ticket = <<~TICKET
      Ticket #{task.external_reference}: #{task.name}
      #{task.description}
    TICKET

    context_parts = [ticket]
    if task.current_brief.present?
      context_parts << "Current brief:\n#{task.current_brief.content}"
    end
    if task.current_detail_draft.present?
      context_parts << "Current detail draft:\n#{task.current_detail_draft.content}"
    end
    if task.project.features_summary.present?
      context_parts << "Codebase feature summary:\n#{task.project.features_summary}"
    end

    <<~PROMPT
      You are a senior tech lead estimating the effort for a single ticket. The
      repository is checked out in your current working directory — use it to
      ground your estimate in the actual codebase, not just the ticket text.

      #{context_parts.join("\n\n")}

      Estimate the story points for THIS ticket only, using the Fibonacci scale
      (1, 2, 3, 5, 8, 13, 21). Do NOT break the ticket into sub-tasks — this is a
      single whole-task estimate.

      Reply with exactly one block:
      <estimate>{"points": <fibonacci number>, "rationale": "<one or two sentences>"}</estimate>
    PROMPT
  end
end
