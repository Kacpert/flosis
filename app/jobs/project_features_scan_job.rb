require "shellwords"

# Daily: pull the latest master of the elvium checkout, then ask the claude CLI
# to summarise the current features + architecture, storing it per Jira-connected
# project in workspaces where Workshop is enabled. The summary feeds the brief
# conversation. A failed git pull, a CLI error, an auth/quota error printed as
# text, or an empty result PRESERVES the previous summary — it never blanks it.
class ProjectFeaturesScanJob < ApplicationJob
  queue_as :default

  CODEBASE_PATH = ENV.fetch("PR_REVIEW_CODEBASE_PATH", File.expand_path("~/work/elvium")).freeze
  CLI_FAILURE_MARKERS = /\b(401|403|429|invalid authentication|failed to authenticate|api error|credit balance|rate limit|usage limit|overloaded|unauthorized)\b/i

  def perform
    return unless pull_latest!

    Workspace.where(workshop_enabled: true).find_each do |workspace|
      workspace.projects.where(external_type: "jira").find_each do |project|
        summary = scan_summary(project)
        next if summary.blank? # preserve prior on failure
        project.update_columns(features_summary: summary, features_summary_updated_at: Time.current)
      end
    end
  end

  private

  def pull_latest!
    out = `cd #{CODEBASE_PATH.shellescape} && git pull --ff-only 2>&1`
    unless $?.success?
      Rails.logger.warn("[FeaturesScan] git pull failed: #{out}")
      return false
    end
    true
  rescue StandardError => e
    Rails.logger.warn("[FeaturesScan] git pull error: #{e.message}")
    false
  end

  def scan_summary(project)
    response = ClaudeCliService.new(codebase_path: CODEBASE_PATH)
                               .start_session(prompt: prompt_for(project))[:response].to_s
    return nil if response.strip.length < 40 || response.match?(CLI_FAILURE_MARKERS)
    response.strip
  rescue ClaudeCliService::ClaudeCliError => e
    Rails.logger.error("[FeaturesScan] claude error for #{project.name}: #{e.message}")
    nil
  end

  def prompt_for(project)
    <<~PROMPT
      Summarise the CURRENT features and main architecture of the application in this
      working directory, for the project "#{project.name}". Read CLAUDE.md, the routes,
      and the main app/ directories. Output a concise plain-text summary (no preamble):
      a bulleted list of the main features the app already has, plus 2–4 sentences on
      the overall architecture (frameworks, main models, how the pieces fit). This is
      reference material for a product owner briefing new work — keep it factual and
      tight, no more than ~400 words.
    PROMPT
  end
end
