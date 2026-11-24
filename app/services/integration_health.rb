# Asks one of a project's integrations whether it still works, and records the
# answer on the project for the topbar's chips. IntegrationHealthJob asks every
# half hour; saving an integration in Configuration asks at once (Kacper,
# 2026-11-24: a new GitHub token stayed red until the next check).
module IntegrationHealth
  INTEGRATIONS = %w[jira github figma].freeze

  module_function

  # The answer ({ ok: true } or { ok: false, error: "..." }), or nil when the
  # project does not use that integration, in which case nothing is recorded.
  def check!(project, integration)
    result = case integration.to_s
             when "jira" then jira(project)
             when "github" then github(project)
             when "figma" then figma(project)
             end
    store(project, integration, result) if result
    result
  end

  # jira_connected? as well as jira_configured?: the domain, login and token
  # fall back to the environment, so a project with no Jira at all still
  # answers "configured" — and would get a green chip, plus an identical API
  # call per tick, for somebody else's Jira.
  def jira(project)
    return unless project.jira_connected?

    credentials = ProjectCredentials.new(project)
    return unless credentials.jira_configured?

    JiraClient.new(domain: credentials.jira_site, email: credentials.jira_email, api_token: credentials.jira_api_token).health_check
  end

  def github(project)
    client = GithubClient.for_project(project)
    client.health_check if client.configured?
  end

  # Only meaningful where the project actually asked the AI to read Figma.
  def figma(project)
    FigmaClient.for_project(project).health_check if project.figma_read_enabled?
  end

  def store(project, integration, result)
    project.update_columns(
      "#{integration}_status_ok" => result[:ok],
      "#{integration}_status_error" => result[:error],
      "#{integration}_status_checked_at" => Time.current
    )
  end
end
