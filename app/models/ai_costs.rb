# What an organization's AI runs cost, read back (SCRUM-70): the figures on
# items, each area's month, and Consumption. Organizations see price only;
# cost and margin are read by /hidmin straight from AiRun.
#
# Rules every figure keeps: a running row counts nowhere; a run with no
# reported cost is counted apart and never as $0 (SUM skips NULL); own-key
# runs are in no total, no limit and no area figure, only on their own line.
# Months are calendar months in the app's time zone (Warsaw).
#
# Production is MariaDB and the tests PostgreSQL, so the SQL here is what both
# understand: CASE WHEN, never FILTER, date_trunc or AT TIME ZONE. A run's
# month is told by comparing ran_at (stored in UTC) with each month's bounds,
# worked out in Ruby (AiSqlPortabilityTest).
class AiCosts
  Figure = Data.define(:total, :this_month, :priced_runs, :runs)
  # priced: how many of the month's runs reported a cost; none → "unknown".
  Month = Data.define(:month, :amount, :runs, :priced)
  # by_area, by_project and own_key_projects rows are [label, runs, amount,
  # priced runs]: a row whose runs were none of them priced reads "unknown".
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
    this_month = AiRun.sanitize_sql_array([ "COALESCE(SUM(CASE WHEN ai_runs.ran_at BETWEEN ? AND ? THEN price_usd END), 0)", month.begin, month.end ])
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
    current = Date.current.beginning_of_month
    span = (0...limit).map { |back| current << back }
    month = month_case(span)
    by_month = workspace_runs.billable.in_area(area).where(ran_at: span.last.in_time_zone..)
                             .group(Arel.sql(month))
                             .pluck(Arel.sql(month), Arel.sql("COALESCE(SUM(price_usd), 0)"), Arel.sql("COUNT(*)"), Arel.sql("COUNT(price_usd)"))
                             .to_h { |at, amount, count, priced| [ at.to_date, [ amount, count, priced ] ] }
    by_month[current] ||= [ BigDecimal("0"), 0, 0 ]
    by_month.sort_by { |month, _| month }.reverse.first(limit)
            .map { |month, (amount, count, priced)| Month.new(month: month, amount: amount, runs: count, priced: priced) }
  end

  # The months with finished runs, newest first, the current month always
  # first: what Consumption's period picker offers.
  def months
    span = months_since_first_run
    found = span.empty? ? [] : workspace_runs.finished.distinct.pluck(Arel.sql(month_case(span))).compact.map(&:to_date)
    ([ Date.current.beginning_of_month ] | found).sort.reverse
  end

  def month(date)
    date = date.to_date.beginning_of_month
    summarize(workspace_runs.in_month(date), limit: AiMonthLimit.for(@workspace, date), months: nil)
  end

  def all_time
    limits = @workspace.ai_month_limits.index_by(&:month)
    span = months_since_first_run
    month = span.empty? ? nil : month_case(span)
    rows = month ? workspace_runs.billable.group(Arel.sql(month)).pluck(Arel.sql(month), Arel.sql("COALESCE(SUM(price_usd), 0)")) : []
    months = rows.reject { |at, _| at.nil? }
                 .map { |at, amount| [ at.to_date, amount, limits[at.to_date] || AiMonthLimit.for(@workspace, at.to_date) ] }
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
    areas = billable.group(:area).pluck(:area, Arel.sql("COUNT(*)"), Arel.sql("COALESCE(SUM(price_usd), 0)"), Arel.sql("COUNT(price_usd)"))
                    .to_h { |area, count, amount, priced| [ area, [ count, amount, priced ] ] }
    Summary.new(
      total: billable.sum(:price_usd),
      runs: billable.count,
      unknown_runs: scope.unknown_cost.count,
      own_key_total: own.sum(:price_usd),
      own_key_projects: by_project(own),
      by_area: AiRun::AREAS.keys.map { |area| [ area, *(areas[area] || [ 0, BigDecimal("0"), 0 ]) ] },
      by_project: by_project(billable),
      months: months,
      limit: limit,
      first_run_at: workspace_runs.finished.minimum(:ran_at)
    )
  end

  # [[name, runs, amount, priced runs]], biggest first. A deleted project keeps
  # its name.
  def by_project(scope)
    rows = scope.group(:project_id, :project_name).pluck(:project_id, :project_name, Arel.sql("COUNT(*)"),
                                                         Arel.sql("COALESCE(SUM(price_usd), 0)"), Arel.sql("COUNT(price_usd)"))
    names = Project.where(id: rows.map(&:first).compact).pluck(:id, :name).to_h
    rows.group_by { |id, name, *| names[id] || name || "No project" }
        .map { |name, group| [ name, group.sum { |row| row[2] }, group.sum { |row| row[3] }, group.sum { |row| row[4] } ] }
        .sort_by { |_, _, amount, _| -amount }
  end

  # Every calendar month from the first finished run's to this one, oldest first.
  def months_since_first_run
    first = workspace_runs.finished.minimum(:ran_at)
    return [] unless first

    month = first.in_time_zone.to_date.beginning_of_month
    current = Date.current.beginning_of_month
    span = []
    while month <= current
      span << month
      month = month.next_month
    end
    span
  end

  # A run's calendar month (as "YYYY-MM-01") among the given months, in SQL any
  # database reads: ran_at is stored in UTC, and each month's bounds are worked
  # out here in the app's time zone (Warsaw, summer time included).
  def month_case(months)
    branches = months.map do |month|
      AiRun.sanitize_sql_array([ "WHEN ai_runs.ran_at >= ? AND ai_runs.ran_at < ? THEN ?",
                                 month.in_time_zone, month.next_month.in_time_zone, month.iso8601 ])
    end
    "CASE #{branches.join(' ')} END"
  end
end
