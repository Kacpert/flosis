# Single source of truth for "what credentials does this project use".
# Resolution order: Project column -> ENV, and ENV only for the two things that
# are genuinely machine-wide (Jira's domain/login and the AI key).
#
# There is deliberately no fallback to the workspace column: with more than one
# client in a workspace, falling back means quietly reviewing one client's repo
# with another client's token. A blank field is the honest answer.
class ProjectCredentials
  def initialize(project)
    @project = project
  end

  def github_repo
    @project.github_repo.presence
  end

  def github_token
    @project.github_token.presence
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

  def figma_token
    @project.figma_token.presence
  end

  def anthropic_api_key
    @project.anthropic_api_key.presence || ENV["ANTHROPIC_API_KEY"].presence
  end

  def github_configured?
    github_repo.present? && github_token.present?
  end

  def jira_configured?
    jira_site.present? && jira_email.present? && jira_api_token.present?
  end

  # A token alone isn't an integration: the AI only reaches Figma where the
  # project asked it to, so the toggle is part of being configured.
  def figma_configured?
    @project.figma_read_enabled? && figma_token.present?
  end
end
