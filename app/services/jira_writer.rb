# Commits a Brief back to Jira: creates the issue (new idea) or updates the
# description (existing task), then sets the "AI actions" field to "Briefed".
# Never raises on a Jira failure — returns { ok: false, error: } so the caller
# can keep the brief in Gold and surface the error instead of silently
# "succeeding". The caller marks the brief briefed ONLY when ok is true.
class JiraWriter
  AI_ACTION_FIELD_NAME = "AI actions".freeze
  BRIEFED_VALUE = "Briefed".freeze

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

    field_id = ai_actions_field_id
    if field_id.present?
      action = @client.add_ai_action(issue_key: key, field_id: field_id, value: BRIEFED_VALUE)
      return { ok: false, error: "Issue saved but couldn't set 'AI actions': #{action[:error]}" } unless action[:ok]
    else
      return { ok: false, error: "Couldn't find the '#{AI_ACTION_FIELD_NAME}' field in Jira" }
    end

    { ok: true, key: key, url: url }
  end

  def ai_actions_field_id
    return @workspace.jira_ai_actions_field_id if @workspace.jira_ai_actions_field_id.present?

    id = @client.fetch_field_id(AI_ACTION_FIELD_NAME)
    @workspace.update_column(:jira_ai_actions_field_id, id) if id.present?
    id
  end
end
