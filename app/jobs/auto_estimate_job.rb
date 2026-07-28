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

  # force: true bypasses the "already estimated" guard — used only by the manual
  # "Estimate" button, where a human explicitly asked to (re-)estimate.
  def perform(task_id, force: false)
    task = Task.find_by(id: task_id)
    return unless task

    return if skip?(task, force: force)

    workspace = task.project.workspace
    response = run_ai(task)
    return if response.nil? # CLI failed to run — do not save, do not crash

    estimate = EstimateParser.extract(response)
    return if estimate.nil? # garbage / no block / not a valid number — no estimate this run

    task.update!(ai_estimate_points: estimate[:points], ai_estimated_at: Time.current)
    write_to_jira(task, workspace, estimate[:points])
  end

  private

  # Estimate a task exactly ONCE. Once it has an AI estimate we never
  # auto-re-estimate — no matter how many syncs run, whether Jira's
  # updated-time moves, or whether the ticket is edited. This is deliberate:
  # auto re-estimation created a feedback loop (our own estimate-write bumped
  # Jira's updated-time → the next sync re-triggered → the value bounced
  # 5→3→5…, spamming Jira watchers). Re-estimating is now only ever a manual,
  # explicit action (the "Estimate" button passes force: true).
  def skip?(task, force: false)
    return false if force
    task.ai_estimate_points.present?
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

    self.class.rubric_prompt(context_parts.join("\n\n"))
  end

  # The estimation prompt, given a ticket-context string. Shared so a
  # DeliveredIssue (title + Jira description only, no brief) can be scored on the
  # exact same 1–100 rubric as a full Task — see BackfillDeliveredEstimatesJob.
  def self.rubric_prompt(ticket_context)
    <<~PROMPT
      You are a senior tech lead scoring the REALISTIC EFFORT of a single ticket
      on a FIXED, CALIBRATED 1–100 scale. This score feeds a fair, cross-time
      comparison of developer output, so CONSISTENCY matters more than anything:
      the SAME ticket must get the SAME score whether scored today or in six
      months. Apply the rubric MECHANICALLY. Do NOT go by gut feel, do NOT drift,
      do NOT invent your own scale. Two tickets with the same rubric criteria MUST
      get the same band.

      The repository is checked out in your current working directory — use it to
      ground your score in the ACTUAL codebase, not just the ticket text.

      #{ticket_context}

      # CRITICAL: estimate the effort it took to BUILD this, not to finish it

      This ticket is very likely ALREADY DONE — its implementation is probably
      already in the codebase. You are scoring how much effort it TOOK TO BUILD the
      whole thing from scratch, NOT how much is left to do now.

      The existing code is EVIDENCE OF THE SCOPE that was built — use it to see how
      many files/models/screens/tests the feature actually spans, how much
      integration and edge-case handling it required, how much it touched. Then
      score the FULL build effort of all of that.

      Do NOT discount for work you can see is already done. NEVER reason "most of
      this already exists, so it's small / only completion work remains" — that is
      exactly backwards. Finding the whole feature already implemented, spanning
      many files with real integration and tests, is a signal it was a BIG task —
      score it HIGH. If the code shows it was substantial to build, score it as
      substantial to build.

      # What the score measures

      REALISTIC delivery effort — the total work it took to BUILD this — for a
      competent developer who USES AI ASSISTANCE to implement (as our team does).
      This is NOT abstract intellectual difficulty — something that sounds complex
      but that AI can implement quickly (boilerplate CRUD, a well-trodden pattern,
      a mechanical refactor) scores LOW. Score is driven by the work AI can't
      shortcut: human judgement, integration surface, edge cases,
      ambiguity/unknowns, testing burden, and risk/blast-radius.

      # The 1–100 rubric (fixed bands — map the ticket to ONE band, then pick a
      # number inside it)

      1–10  TRIVIAL — one file, no real logic, no edge cases. Copy/label change, a
            constant, a tiny config tweak. AI does essentially all of it.
      11–25 SMALL — 1–2 files, minor logic, obvious approach, few/no edge cases.
            AI implements it fast; little human judgement needed.
      26–45 MODERATE — a self-contained feature or fix: a handful of files, some
            edge cases, a bit of integration, straightforward testing. AI does the
            bulk; some human wiring/decisions.
      46–65 SUBSTANTIAL — multi-file feature with real integration, several edge
            cases, non-trivial testing, or touching a shared/used-in-many-places
            area. Needs meaningful human judgement even with AI.
      66–85 COMPLEX — cross-cutting change, tricky logic or state, notable risk or
            blast-radius, meaningful unknowns to resolve, heavy testing. AI helps
            but a lot of careful human work remains.
      86–100 MAJOR — architectural / spanning many systems, high uncertainty or
            research needed, high risk, large integration + testing burden. AI
            provides limited leverage; mostly hard human work.

      # Calibration anchors (use these to stay consistent)

      - Rename a button label / fix a typo in copy → ~5
      - Add a new field to an existing form + validation + save → ~20
      - Add a filter/search to an existing list view → ~30
      - New endpoint + UI that integrates with one existing service, with edge
        cases → ~55
      - Change that touches auth/permissions or a widely-used model, with real
        risk and broad testing → ~75
      - New subsystem or a migration spanning many models/screens with unknowns → ~92

      # How to score

      1. Read the ticket and inspect the code that implements it. Judge the TOTAL
         real work it took to BUILD the whole thing (given AI assistance) — from
         nothing to the finished feature you see in the code. Not the work "left".
      2. Pick the ONE band whose criteria the built feature best matches.
      3. Choose a specific number inside that band (don't just pick the midpoint —
         reflect where in the band it sits).
      4. Score the WHOLE ticket as one unit. Do NOT break it into sub-tasks.

      Reply with exactly one block:
      <estimate>{"score": <integer 1-100>, "rationale": "<band + the 1-2 criteria that placed it there, one or two sentences>"}</estimate>
    PROMPT
  end
end
