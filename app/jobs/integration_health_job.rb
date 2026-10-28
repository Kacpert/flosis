# Asks each integration whether it still works, and records the answer on the
# project so the topbar chips can tell the truth.
#
# A chip that goes green on "somebody filled this field in" is worse than no
# chip: a Figma token expired without a sound, and the first sign of it was the
# AI telling a client it couldn't open the design. Credentials rot on their own
# — tokens expire, get revoked, lose a scope — so something has to keep asking.
#
# GitHub keeps its existing per-poll check in PrReviewCheckJob (that one runs
# far more often); this fills it in too for projects where PR review is off.
class IntegrationHealthJob < ApplicationJob
  queue_as :default

  def perform
    Project.active.find_each do |project|
      check_jira(project)
      check_github(project)
      check_figma(project)
    rescue StandardError => e
      # One broken project must not stop the rest from being checked.
      Rails.logger.error("[IntegrationHealthJob] project #{project.id} failed: #{e.message}")
    end
  end

  private

  # jira_connected? as well as jira_configured?: the domain, login and token
  # fall back to the environment, so a project with no Jira at all still
  # answers "configured" — and would get a green chip, plus an identical API
  # call per tick, for somebody else's Jira.
  def check_jira(project)
    return unless project.jira_connected?

    credentials = ProjectCredentials.new(project)
    return unless credentials.jira_configured?

    store(project, :jira, JiraClient.new(domain: credentials.jira_site,
                                         email: credentials.jira_email,
                                         api_token: credentials.jira_api_token).health_check)
  end

  def check_github(project)
    client = GithubClient.for_project(project)
    return unless client.configured?

    store(project, :github, client.health_check)
  end

  def check_figma(project)
    # Only meaningful where the project actually asked the AI to read Figma.
    return unless project.figma_read_enabled?

    store(project, :figma, FigmaClient.for_project(project).health_check)
  end

  def store(project, integration, result)
    project.update_columns(
      "#{integration}_status_ok" => result[:ok],
      "#{integration}_status_error" => result[:error],
      "#{integration}_status_checked_at" => Time.current
    )
  end
end
