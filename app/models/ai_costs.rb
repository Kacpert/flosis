# What an organization's AI runs cost, read back (SCRUM-70): the figures on
# items, each area's month, and Consumption. Organizations see price only;
# cost and margin are read by /hidmin straight from AiRun.
#
# Rules every figure keeps: a running row counts nowhere; a run with no
# reported cost is counted apart and never as $0 (SUM skips NULL); own-key
# runs are in no total, no limit and no area figure, only on their own line.
# Months are calendar months in the app's time zone (Warsaw).
class AiCosts
  Figure = Data.define(:total, :this_month, :priced_runs, :runs)
  Month = Data.define(:month, :amount, :runs)
  Summary = Data.define(:total, :runs, :unknown_runs, :own_key_total, :own_key_projects, :by_area, :by_project,
                        :months, :limit, :first_run_at)

  def initialize(workspace)
    @workspace = workspace
  end

  # Each item's total and this month's part, for one area: one grouped query
  # for a whole page of items. Own-key runs count here, at their price (their
  # cost): the item did cost that. Keyed by [polymorphic type, id].
  def item_figures(items, area:)
    items = Array(items).compact.select(&:persisted?)
    return {} if items.empty?

    month = Date.current.in_time_zone.all_month
    this_month = AiRun.sanitize_sql_array([ "COALESCE(SUM(price_usd) FILTER (WHERE ran_at BETWEEN ? AND ?), 0)", month.begin, month.end ])
    workspace_runs.finished.in_area(area)
        .where(item_type: items.map { |item| item.class.polymorphic_name }.uniq, item_id: items.map(&:id))
        .group(:item_type, :item_id)
        .pluck(:item_type, :item_id, Arel.sql("COALESCE(SUM(price_usd), 0)"), Arel.sql(this_month),
               Arel.sql("COUNT(price_usd)"), Arel.sql("COUNT(*)"))
        .to_h { |type, id, total, now, priced, all| [ [ type, id ], Figure.new(total: total, this_month: now, priced_runs: priced, runs: all) ] }
  end

  # The area's billable spend by month, newest first, the current month always
  # first even with nothing in it.
  def area_months(area, limit: 12)
    by_month = workspace_runs.billable.in_area(area).group(Arel.sql(month_sql)).pluck(Arel.sql(month_sql), Arel.sql("COALESCE(SUM(price_usd), 0)"), Arel.sql("COUNT(*)"))
                   .to_h { |month, amount, count| [ month.to_date, [ amount, count ] ] }
    current = Date.current.beginning_of_month
    by_month[current] ||= [ BigDecimal("0"), 0 ]
    by_month.sort_by { |month, _| month }.reverse.first(limit).map { |month, (amount, count)| Month.new(month: month, amount: amount, runs: count) }
  end

  # The months with finished runs, newest first, the current month always
  # first: what Consumption's period picker offers.
  def months
    found = workspace_runs.finished.distinct.pluck(Arel.sql(month_sql)).map(&:to_date)
    ([ Date.current.beginning_of_month ] | found).sort.reverse
  end

  def month(date)
    date = date.to_date.beginning_of_month
    summarize(workspace_runs.in_month(date), limit: AiMonthLimit.for(@workspace, date), months: nil)
  end

  def all_time
    limits = @workspace.ai_month_limits.index_by(&:month)
    months = workspace_runs.billable.group(Arel.sql(month_sql)).pluck(Arel.sql(month_sql), Arel.sql("COALESCE(SUM(price_usd), 0)"))
                 .map { |month, amount| [ month.to_date, amount, limits[month.to_date] || AiMonthLimit.for(@workspace, month.to_date) ] }
                 .sort_by(&:first).reverse
    summarize(workspace_runs, limit: nil, months: months)
  end

  # The month's finished runs, newest first, a page at a time.
  def runs(date, offset: 0, limit: 50)
    workspace_runs.finished.in_month(date.to_date).order(ran_at: :desc, id: :desc).offset(offset).limit(limit)
                  .includes(:started_by, :project).preload(:item)
  end

  private

  def workspace_runs
    AiRun.where(workspace_id: @workspace.id)
  end

  def summarize(scope, limit:, months:)
    billable = scope.billable
    own = scope.own_keyed
    areas = billable.group(:area).pluck(:area, Arel.sql("COUNT(*)"), Arel.sql("COALESCE(SUM(price_usd), 0)")).to_h { |area, count, amount| [ area, [ count, amount ] ] }
    Summary.new(
      total: billable.sum(:price_usd),
      runs: billable.count,
      unknown_runs: scope.unknown_cost.count,
      own_key_total: own.sum(:price_usd),
      own_key_projects: by_project(own),
      by_area: AiRun::AREAS.keys.map { |area| [ area, *(areas[area] || [ 0, BigDecimal("0") ]) ] },
      by_project: by_project(billable),
      months: months,
      limit: limit,
      first_run_at: workspace_runs.finished.minimum(:ran_at)
    )
  end

  # [[name, runs, amount]], biggest first. A deleted project keeps its name.
  def by_project(scope)
    rows = scope.group(:project_id, :project_name).pluck(:project_id, :project_name, Arel.sql("COUNT(*)"), Arel.sql("COALESCE(SUM(price_usd), 0)"))
    names = Project.where(id: rows.map(&:first).compact).pluck(:id, :name).to_h
    rows.group_by { |id, name, _, _| names[id] || name || "No project" }
        .map { |name, group| [ name, group.sum { |row| row[2] }, group.sum { |row| row[3] } ] }
        .sort_by { |_, _, amount| -amount }
  end

  # A run's calendar month in the app's time zone (ran_at is stored in UTC).
  def month_sql
    zone = Time.zone.tzinfo.name
    "date_trunc('month', (ai_runs.ran_at AT TIME ZONE 'UTC') AT TIME ZONE #{AiRun.connection.quote(zone)})"
  end
end
