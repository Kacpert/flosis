# Commits a Brief back to Jira: creates the issue (new idea) or updates the
# description (existing task), then sets the "AI actions" field to "Briefed".
# Never raises on a Jira failure — returns { ok: false, error: } so the caller
# can keep the brief in Gold and surface the error instead of silently
# "succeeding". The caller marks the brief briefed ONLY when ok is true.
class JiraWriter
  AI_ACTION_FIELD_NAME = "AI actions".freeze
  BRIEFED_VALUE = "Briefed".freeze
  SPEC_VALUE = "Added specification and branch".freeze
  DETAILED_VALUE = "Detailed".freeze

  def initialize(workspace:, client: JiraClient.new)
    @workspace = workspace
    @client = client
  end

  def commit_brief(brief)
    task = brief.task

    if task.external_reference.present?
      res = @client.update_issue_description(issue_key: task.external_reference,
                                             description_text: plain_text(brief.content))
      return res unless res[:ok]
      key = task.external_reference
      url = task.external_url
    else
      project_key = task.project.external_reference
      return { ok: false, error: "Project is not linked to Jira" } if project_key.blank?

      res = @client.create_issue(project_key: project_key, summary: task.name,
                                 description_text: plain_text(brief.content))
      return res unless res[:ok]
      key = res[:key]
      url = res[:url]
      task.update!(external_reference: key, external_url: url, external_type: "jira")
    end

    # The description write above is what matters. Setting the "AI actions" field
    # is a nice-to-have — if only that fails (e.g. the field's option names don't
    # match), the push still SUCCEEDED; surface a soft warning, don't fail.
    action = set_ai_action(key, BRIEFED_VALUE)
    { ok: true, key: key, url: url, warning: action[:ok] ? nil : action[:error] }
  end

  # Pushes a details-stage AI draft's content to Jira and marks it "Detailed".
  # If the task is already linked, updates the existing issue's description. If
  # it's a LOCAL idea (no Jira key yet), CREATES the Jira issue from the draft
  # and links the task — so "Push to Jira" at Details turns a local idea into a
  # real Jira ticket in one step.
  def commit_detail(draft)
    task = draft.task

    if task.external_reference.present?
      res = @client.update_issue_description(issue_key: task.external_reference,
                                             description_text: plain_text(draft.content))
      return res unless res[:ok]
      key = task.external_reference
    else
      project_key = task.project.external_reference
      return { ok: false, error: "Project is not linked to Jira" } if project_key.blank?

      res = @client.create_issue(project_key: project_key, summary: task.name,
                                 description_text: plain_text(draft.content))
      return res unless res[:ok]
      key = res[:key]
      task.update!(external_reference: key, external_url: res[:url], external_type: "jira")
    end

    # AI-actions field is best-effort — a failure there must not fail the push
    # (the description saved fine). Surface it as a soft warning instead.
    action = set_ai_action(key, DETAILED_VALUE)
    draft.update!(pushed_at: Time.current)
    { ok: true, key: key, warning: action[:ok] ? nil : action[:error] }
  end

  # Pushes the latest breakdown (spec) to the linked Jira issue's description and
  # sets the "AI actions" field to "Added specification and branch".
  def commit_breakdown(task)
    return { ok: false, error: "Task is not linked to Jira" } if task.external_reference.blank?
    breakdown = task.latest_breakdown
    return { ok: false, error: "No breakdown to push" } if breakdown.blank?

    text = format_breakdown(breakdown.content)
    res = @client.update_issue_description(issue_key: task.external_reference, description_text: text)
    return res unless res[:ok]

    field_id = ai_actions_field_id
    return { ok: false, error: "Couldn't find the '#{AI_ACTION_FIELD_NAME}' field in Jira" } if field_id.blank?

    action = @client.add_ai_action(issue_key: task.external_reference, field_id: field_id, value: SPEC_VALUE)
    action[:ok] ? { ok: true, key: task.external_reference } : { ok: false, error: action[:error] }
  end

  # Rewrites the delimited "--- Designs ---" block in the task's description
  # IDEMPOTENTLY: a single header line followed by one "{name}: {url}" line
  # per link, always at the very end of the description. Called on delivery,
  # on per-link removal, and on request-changes, so the IN DESCRIPTION badge
  # is always truthful. Removing the last link removes the whole block.
  #
  # The block lives in `task.description` (the local mirror) first — this is
  # the single source of truth the regex rewrites — then the FULL updated
  # description is pushed to Jira via update_issue_description when the task
  # is linked (external_reference present). A local-only task just updates
  # the mirror; never raises either way (matches the rest of JiraWriter).
  DESIGNS_BLOCK_HEADER = "--- Designs ---".freeze
  DESIGNS_BLOCK_PATTERN = /\n*#{Regexp.escape(DESIGNS_BLOCK_HEADER)}\n(?:.*\n?)*\z/

  def sync_design_links(task, links)
    base = task.description.to_s.sub(DESIGNS_BLOCK_PATTERN, "").rstrip
    new_description =
      if links.blank?
        base
      else
        lines = links.map { |l| "#{l["name"] || l[:name]}: #{l["url"] || l[:url]}" }
        [base, "", DESIGNS_BLOCK_HEADER, *lines].join("\n")
      end

    task.update!(description: new_description)

    return { ok: true } if task.external_reference.blank?

    res = @client.update_issue_description(issue_key: task.external_reference, description_text: new_description)
    res[:ok] ? { ok: true } : { ok: false, error: res[:error] }
  end

  def ai_actions_field_id
    return @workspace.jira_ai_actions_field_id if @workspace.jira_ai_actions_field_id.present?

    id = @client.fetch_field_id(AI_ACTION_FIELD_NAME)
    @workspace.update_column(:jira_ai_actions_field_id, id) if id.present?
    id
  end

  # Rich-text editing (Task 5.2) lets a brief/draft's `content` be stored as
  # sanitized HTML instead of plain text/markdown. Jira must never receive raw
  # tags, so every push point flattens content through this helper first.
  # Rails::Html::FullSanitizer strips tags entirely (not just an allowlist) —
  # safe to run unconditionally since it's a no-op on tag-free text (plain
  # text or markdown like "## Foo" survives untouched).
  def self.plain_text(content)
    text = Rails::Html::FullSanitizer.new.sanitize(content.to_s)
    text.gsub(/\n{3,}/, "\n\n").strip
  end

  private

  def plain_text(content)
    self.class.plain_text(content)
  end

  # Sets the "AI actions" field on the given issue to `value`. Shared by
  # commit_brief (BRIEFED_VALUE) and commit_detail (DETAILED_VALUE).
  def set_ai_action(issue_key, value)
    field_id = ai_actions_field_id
    return { ok: false, error: "Couldn't find the '#{AI_ACTION_FIELD_NAME}' field in Jira" } if field_id.blank?

    action = @client.add_ai_action(issue_key: issue_key, field_id: field_id, value: value)
    return { ok: false, error: "Issue saved but couldn't set 'AI actions': #{action[:error]}" } unless action[:ok]

    { ok: true }
  end

  # Flatten a breakdown JSON document into a plain-text description for Jira.
  def format_breakdown(json)
    data = JSON.parse(json) rescue {}
    lines = []
    lines << "Strategy: #{data['strategy']}" if data["strategy"].present?
    Array(data["subtasks"]).each do |st|
      lines << "• #{st['title']} (#{st['points']} pts): #{st['description']}"
      Array(st["acceptance_criteria"]).each { |ac| lines << "    - #{ac}" }
    end
    lines << "Total points: #{data['total_points']}" if data["total_points"].present?
    lines.join("\n")
  end
end
