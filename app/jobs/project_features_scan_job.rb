require "shellwords"

# Daily: for each Jira-connected project in a Workshop workspace, pull the
# latest master of THAT project's checkout and ask the claude CLI to summarise
# its features. The summary feeds the brief conversation, so it has to describe
# the project it is stored on — one shared checkout meant every project's brief
# was briefed on the same codebase. A project with no checkout of its own is
# skipped. A failed git pull, a CLI error, an auth/quota error printed as text,
# or an empty result PRESERVES the previous summary — it never blanks it.
class ProjectFeaturesScanJob < ApplicationJob
  queue_as :default
  include WaitsForDesignImport

  CLI_FAILURE_MARKERS = /\b(401|403|429|invalid authentication|failed to authenticate|api error|credit balance|rate limit|usage limit|overloaded|unauthorized)\b/i

  # No project_id → the daily sweep over every Workshop project.
  # With project_id → a single-project refresh (the manual "Refresh" button).
  # Returns true when a single-project scan actually updated the summary.
  def perform(project_id = nil)
    if project_id
      project = Project.find_by(id: project_id)
      return false unless project
      return scan_and_store(project)
    end

    Workspace.where(workshop_enabled: true).find_each do |workspace|
      workspace.projects.where(external_type: "jira").find_each do |project|
        scan_and_store(project)
      end
    end
  end

  private

  # Scans one project and stores the summary, preserving the prior value on any
  # failure (blank/CLI error). Returns true only when a new summary was stored.
  def scan_and_store(project)
    codebase = ai_codebase_path(project)
    return false if codebase.nil?
    return false unless pull_latest!(codebase)

    summary = scan_summary(project, codebase)
    return false if summary.blank? # preserve prior on failure
    project.update_columns(features_summary: summary, features_summary_updated_at: Time.current)
    true
  end

  def pull_latest!(codebase)
    out = `cd #{codebase.shellescape} && git pull --ff-only 2>&1`
    unless $?.success?
      Rails.logger.warn("[FeaturesScan] git pull failed in #{codebase}: #{out}")
      return false
    end
    true
  rescue StandardError => e
    Rails.logger.warn("[FeaturesScan] git pull error in #{codebase}: #{e.message}")
    false
  end

  def scan_summary(project, codebase)
    response = ClaudeCliService.new(codebase_path: codebase)
                               .start_session(prompt: prompt_for(project))[:response].to_s
    return nil if response.strip.length < 40 || response.match?(CLI_FAILURE_MARKERS)
    response.strip
  rescue ClaudeCliService::ClaudeCliError => e
    Rails.logger.error("[FeaturesScan] claude error for #{project.name}: #{e.message}")
    nil
  end

  def prompt_for(project)
    <<~PROMPT
      Read the application in this working directory (CLAUDE.md, the routes, and the
      main app/ directories) for the project "#{project.name}", and produce a
      plain-language list of WHAT THE APP DOES FOR ITS USERS — the features and
      capabilities that already exist, described the way a product person would.

      This is reference material for a product owner briefing new work, so a
      non-technical reader must fully understand it:
      - Bulleted list of the main features / things a user can do today.
      - Group related features if helpful.
      - Describe them in terms of user-facing behaviour and value, NOT implementation.
      - Do NOT mention code, file paths, class/model/table names, frameworks,
        libraries, or database/API details. No architecture section.
      - No preamble. Factual and tight, no more than ~400 words.
    PROMPT
  end
end
