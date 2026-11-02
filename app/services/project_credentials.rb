# Single source of truth for "what credentials does this project use".
# Resolution order: Project column -> the machine's own configuration, and only
# for the things that are genuinely machine-wide (Jira's domain/login, the AI
# key, and the Figma key the Claude CLI is already set up with).
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

  # A project on a Jira site of its own (another organization's) never gets
  # the machine's login: that would send the server's token to that site.
  def jira_email
    @project.jira_email.presence || (ENV["JIRA_EMAIL"].presence unless own_jira_site?)
  end

  def jira_api_token
    @project.jira_api_token.presence || (ENV["JIRA_API_TOKEN"].presence unless own_jira_site?)
  end

  def own_jira_site?
    @project.jira_site.present? && @project.jira_site != ENV["JIRA_DOMAIN"]
  end

  def jira_key
    @project.external_reference.presence
  end

  # The one place the Figma fallback happens. It used to live in
  # FigmaClient.for_project alone, so the health check resolved the CLI's key
  # while ProjectMcpConfig gated on the column: the chip went green and the AI
  # was handed no Figma server at all.
  def figma_token
    @project.figma_token.presence || FigmaClient.cli_token
  end

  def anthropic_api_key
    @project.anthropic_api_key.presence || ENV["ANTHROPIC_API_KEY"].presence
  end

  # The key a Designs turn runs on: the project's own, and nothing else. The
  # method above falls back to the machine's key, and this one must not.
  #
  # Licensing: Anthropic's terms do not let one party's Claude subscription
  # serve other people. Claude Code's "Legal and compliance" page has each end
  # user of a product built on it authenticate with their own key (Consumer
  # Terms section 2 says the same of a subscription), and from 2026-11-12 the
  # Usage Policy bans services that route requests through consumer
  # subscriptions. The server is logged in to the owner's own, so a client's
  # design work either runs on the client's key or does not run: a project
  # without one is told to add it (Configuration › AI) and starts no turn,
  # rather than quietly borrowing the server's.
  def designs_api_key
    @project.anthropic_api_key.presence
  end

  # The design repo and its token come from the project and from nowhere else,
  # least of all github_repo and github_token. The design token has write
  # access (Designs pushes a branch per task), and the app repo's token is a
  # different key for a different repository: borrowing it would push with the
  # wrong scope.
  def design_repo
    @project.design_repo.presence
  end

  def design_repo_token
    @project.design_repo_token.presence
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

  def design_repo_configured?
    design_repo.present? && design_repo_token.present?
  end

  # Every credential Flosis could hand to anything for this project, for the
  # leak guard to keep out of its design repo: each one the project stores
  # (every encrypted column, so one added to the model later is included
  # without anyone remembering this) and the machine's own, which the
  # fallbacks above hand to the AI when the project has none.
  def all_secrets
    stored = Project.encrypted_attributes.map { |attribute| @project.public_send(attribute) }
    machine = [ ENV["JIRA_API_TOKEN"], ENV["ANTHROPIC_API_KEY"], FigmaClient.cli_token ]
    (stored + machine).compact_blank.uniq
  end
end
