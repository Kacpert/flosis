# Single source of truth for "what credentials does this project use".
# Resolution order: Project column -> Workspace column -> ENV (Jira only).
# Consumed by ProjectMcpConfig, GithubClient.for_project, and automation
# JiraClient instantiation. Legacy HR / PrReviewJob do NOT use this.
class ProjectCredentials
  def initialize(project)
    @project = project
    @workspace = project.workspace
  end

  def github_repo
    @project.github_repo.presence || @workspace&.github_repo.presence
  end

  def github_token
    @project.github_token.presence || @workspace&.github_token.presence
  end

  def jira_site
    @project.jira_site.presence || ENV["JIRA_DOMAIN"].presence
  end

  def jira_email
    @project.jira_email.presence || ENV["JIRA_EMAIL"].presence
  end

  def jira_api_token
    @project.jira_api_token.presence || ENV["JIRA_API_TOKEN"].presence
  end

  def jira_key
    @project.external_reference.presence
  end

  def github_configured?
    github_repo.present? && github_token.present?
  end

  def jira_configured?
    jira_site.present? && jira_email.present? && jira_api_token.present?
  end
end
