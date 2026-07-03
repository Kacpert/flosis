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
      res = @client.update_issue_description(issue_key: task.external_reference, description_text: brief.content)
      return res unless res[:ok]
      key = task.external_reference
      url = task.external_url
    else
      project_key = task.project.external_reference
      return { ok: false, error: "Project is not linked to Jira" } if project_key.blank?

      res = @client.create_issue(project_key: project_key, summary: task.name, description_text: brief.content)
      return res unless res[:ok]
      key = res[:key]
      url = res[:url]
      task.update!(external_reference: key, external_url: url, external_type: "jira")
    end

    action = set_ai_action(key, BRIEFED_VALUE)
    return action unless action[:ok]

    { ok: true, key: key, url: url }
  end

  # Pushes a details-stage AI draft's content to the linked Jira issue's
  # description and sets the "AI actions" field to "Detailed". Local ideas
  # (no Jira key yet) cannot receive a details push — the issue is only ever
  # created via commit_brief.
  def commit_detail(draft)
    task = draft.task
    return { ok: false, error: "Task is not linked to Jira" } if task.external_reference.blank?

    res = @client.update_issue_description(issue_key: task.external_reference,
                                           description_text: draft.content)
    return res unless res[:ok]

    action = set_ai_action(task.external_reference, DETAILED_VALUE)
    return action unless action[:ok]

    draft.update!(pushed_at: Time.current)
    { ok: true }
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

  def ai_actions_field_id
    return @workspace.jira_ai_actions_field_id if @workspace.jira_ai_actions_field_id.present?

    id = @client.fetch_field_id(AI_ACTION_FIELD_NAME)
    @workspace.update_column(:jira_ai_actions_field_id, id) if id.present?
    id
  end

  private

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
