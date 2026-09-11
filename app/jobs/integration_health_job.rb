# Asks each integration whether it still works, and records the answer on the
# workspace so the topbar chips can tell the truth.
#
# A chip that goes green on "somebody filled this field in" is worse than no
# chip: a Figma token expired without a sound, and the first sign of it was the
# AI telling a client it couldn't open the design. Credentials rot on their own
# — tokens expire, get revoked, lose a scope — so something has to keep asking.
#
# GitHub keeps its existing per-poll check in PrReviewCheckJob (that one runs
# far more often); this fills it in too for workspaces where PR review is off.
class IntegrationHealthJob < ApplicationJob
  queue_as :default

  def perform
    Workspace.find_each do |workspace|
      check_jira(workspace)
      check_github(workspace)
      check_figma(workspace)
    rescue StandardError => e
      # One broken workspace must not stop the rest from being checked.
      Rails.logger.error("[IntegrationHealthJob] workspace #{workspace.id} failed: #{e.message}")
    end
  end

  private

  def check_jira(workspace)
    project = workspace.projects.active.find_by(external_type: "jira")
    return unless project

    result = JiraClient.new(**jira_credentials(project)).health_check
    store(workspace, :jira, result)
  end

  # Per-project credentials when set, the app-wide ENV otherwise — the same
  # resolution the rest of the app uses.
  def jira_credentials(project)
    creds = ProjectCredentials.new(project)
    { domain: creds.jira_site, email: creds.jira_email, api_token: creds.jira_api_token }
  end

  def check_github(workspace)
    client = GithubClient.for(workspace)
    return unless client.configured?

    store(workspace, :github, client.health_check)
  end

  def check_figma(workspace)
    # Only meaningful where the workspace actually asked the AI to read Figma.
    return unless workspace.figma_read_enabled?

    store(workspace, :figma, FigmaClient.for_cli.health_check)
  end

  def store(workspace, integration, result)
    workspace.update_columns(
      "#{integration}_status_ok" => result[:ok],
      "#{integration}_status_error" => result[:error],
      "#{integration}_status_checked_at" => Time.current
    )
  end
end
