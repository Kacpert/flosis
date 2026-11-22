require "test_helper"

# Production runs MariaDB (mysql2); tests run PostgreSQL. The AI cost queries
# must stay in SQL both understand — the rest of the app's rule too (LOWER
# LIKE, not ILIKE). This catches PostgreSQL-only syntax before it reaches
# production.
class AiSqlPortabilityTest < ActiveSupport::TestCase
  POSTGRES_ONLY = /FILTER\s*\(|date_trunc|AT TIME ZONE|::[a-z]|\bILIKE\b|\bjsonb\b/i

  setup do
    @workspace = workspaces(:one)
    AiRun.create!(workspace: @workspace, project: projects(:jira_project), area: "pr_reviews", automation: "PR review",
                  status: "succeeded", ran_at: 40.days.ago, cost_usd: 1, price_usd: 1.3, margin_percent: 30)
  end

  def sql_of
    statements = []
    callback = ->(*, payload) { statements << payload[:sql] unless payload[:name] == "SCHEMA" }
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { yield }
    statements
  end

  test "the organization's cost queries are portable SQL" do
    costs = AiCosts.new(@workspace)
    statements = sql_of do
      costs.item_figures([ tasks(:jira_task) ], area: "pr_reviews")
      costs.area_months("pr_reviews")
      costs.months
      costs.month(Date.current)
      costs.all_time
      costs.runs(Date.current).to_a
    end
    offending = statements.grep(POSTGRES_ONLY)
    assert_empty offending, offending.join("\n")
  end

  test "the staff billing queries are portable SQL" do
    billing = AiBilling.new(@workspace)
    statements = sql_of do
      AiBilling.organizations
      billing.cost
      billing.margins
      billing.by_area
      billing.by_project
      billing.own_key_projects
      billing.unknown_runs.to_a
      billing.recent_runs.to_a
    end
    offending = statements.grep(POSTGRES_ONLY)
    assert_empty offending, offending.join("\n")
  end

  test "the migration uses no PostgreSQL-only column types or partial indexes" do
    source = File.read(Rails.root.join("db/migrate/20261122100000_create_ai_billing.rb"))
    refute_match(/\.jsonb\b/, source)
    refute_match(/\bwhere:/, source)
  end
end
