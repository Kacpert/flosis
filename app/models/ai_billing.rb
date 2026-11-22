# Cost and price side by side, for Flosis staff only (SCRUM-70, /hidmin):
# what the provider reported against what each organization is charged, and
# the margin kept between them. Organizations read AiCosts, which carries no
# cost or margin. Own-key runs are billed to the client by Anthropic: they are
# shown apart and are in no total.
class AiBilling
  Row = Data.define(:label, :cost, :price, :runs)
  Organization = Data.define(:cost, :price, :runs, :unknown)

  # This month's figures for every organization at once:
  # { workspace_id => Organization }.
  def self.organizations(month = Date.current)
    scope = AiRun.billable.in_month(month)
    sums = scope.group(:workspace_id).pluck(:workspace_id, Arel.sql("COALESCE(SUM(cost_usd), 0)"),
                                            Arel.sql("COALESCE(SUM(price_usd), 0)"), Arel.sql("COUNT(*)"))
    unknown = AiRun.unreviewed_unknown.group(:workspace_id).count
    (sums.map(&:first) | unknown.keys).to_h do |id|
      _, cost, price, runs = sums.find { |row| row.first == id } || [ id, 0, 0, 0 ]
      [ id, Organization.new(cost: cost, price: price, runs: runs, unknown: unknown.fetch(id, 0)) ]
    end
  end

  attr_reader :month

  def initialize(workspace, month = Date.current)
    @workspace = workspace
    @month = month.to_date.beginning_of_month
  end

  def billable = runs_in_month.billable

  def cost = billable.sum(:cost_usd)
  def price = billable.sum(:price_usd)
  def runs_count = billable.count
  def priced_runs_count = billable.where.not(cost_usd: nil).count

  # The margins this month's runs were priced with, each from the first day it
  # was used: [[margin, first ran_at]], oldest first.
  def margins
    billable.where.not(margin_percent: nil).group(:margin_percent).minimum(:ran_at).sort_by { |_, at| at }
  end

  def by_area
    rows = billable.group(:area).pluck(:area, *sums).to_h { |area, *values| [ area, values ] }
    AiRun::AREAS.filter_map do |area, label|
      cost, price, runs = rows[area]
      Row.new(label: label, cost: cost, price: price, runs: runs) if runs
    end
  end

  def by_project(scope = billable)
    rows = scope.group(:project_id, :project_name).pluck(:project_id, :project_name, *sums)
    names = Project.where(id: rows.map(&:first).compact).pluck(:id, :name).to_h
    rows.group_by { |id, name, *| names[id] || name || "No project" }
        .map { |label, group| Row.new(label: label, cost: group.sum { |r| r[2] }, price: group.sum { |r| r[3] }, runs: group.sum { |r| r[4] }) }
        .sort_by { |row| -row.price }
  end

  def own_key_projects = by_project(runs_in_month.own_keyed)
  def own_key_total = runs_in_month.own_keyed.sum(:cost_usd)

  def unknown_runs
    AiRun.where(workspace_id: @workspace.id).unreviewed_unknown.order(ran_at: :desc).includes(:started_by)
  end

  def recent_runs(limit: 20)
    runs_in_month.finished.order(ran_at: :desc, id: :desc).limit(limit).includes(:started_by).preload(:item)
  end

  def limit = AiMonthLimit.for(@workspace, @month)

  private

  def runs_in_month = AiRun.where(workspace_id: @workspace.id).in_month(@month)

  def sums
    [ Arel.sql("COALESCE(SUM(cost_usd), 0)"), Arel.sql("COALESCE(SUM(price_usd), 0)"), Arel.sql("COUNT(*)") ]
  end
end
