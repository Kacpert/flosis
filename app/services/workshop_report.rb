# Workshop Reporting (Task 7.1): throughput/cost dashboard query object. Pure
# read model — no controller dependencies, unit-testable in isolation.
#
# HR BOUNDARY: all "done"/delivered data reads `delivered_issues` (Task 6.2's
# mirror), NEVER `tasks` — HR's Projects screen renders `project.tasks.size`,
# so delivered work must never leak into `tasks`. The only `tasks` reads this
# class performs are the "new bugs this period" union (open Bugs) and the
# bugs_created reporter-fallback (open Bugs by reporter_email) — both
# explicitly called out below.
#
# Portable SQL: LOWER(...) LIKE (not ILIKE — must run on MySQL in production);
# no window functions — bucketing for `trend` is done in Ruby.
class WorkshopReport
  BUG = "Bug".freeze

  def initialize(project:, period: :month, developer: nil, month: nil, sprint: nil)
    @project = project
    @period = period
    @developer = developer
    @month = clamp_month(month)
    # An explicitly navigated-to sprint (Reporting's ‹ › arrows). nil = the
    # project's currently active sprint, the previous behaviour.
    @sprint = sprint
    @from, @to, @active_sprint = resolve_period(period)
  end

  attr_reader :from, :to, :active_sprint

  # The month this report covers (a Date at the 1st), for labelling/navigation.
  # Always the current month when none was selected.
  def selected_month
    @month || Time.current.beginning_of_month.to_date
  end

  # The project's currently active JiraSprint (regardless of which `period`
  # this report was built with) — used by the view to label the Sprint tab
  # ("{active sprint name}") even while the Month tab is selected.
  def current_active_sprint
    @current_active_sprint ||= active_sprint_for(@project)
  end

  # ---------------------------------------------------------------------
  # metrics
  # ---------------------------------------------------------------------

  def metrics
    {
      # "Features delivered" stays features-only (bugs aren't features), but
      # "Completed (story points)" / SP DONE counts ALL delivered work by
      # complexity — bugs included — so bug-heavy devs aren't shown as doing
      # nothing. BUGS FIXED remains a separate count.
      features_delivered_count: features_delivered.count,
      features_delivered_points: sum_points(features_delivered),
      completed_story_points: sum_points(delivered_in_period),
      new_bugs: new_bugs_count,
      hours: hours_for(completed_time_entries),
      cost_cents: cost_cents_for(completed_time_entries)
    }
  end

  # ---------------------------------------------------------------------
  # developers
  # ---------------------------------------------------------------------

  def developers
    emails = developer_emails
    emails.map { |email| developer_row(email) }.compact
  end

  # ---------------------------------------------------------------------
  # trend
  # ---------------------------------------------------------------------

  # `range` is a bucket COUNT, not a month count — the caller (Workshop::
  # ReportsController#bucket_count) converts the user-facing "last N months"
  # window into however many weeks/fortnights/months/sprints that spans.
  def trend(granularity:, range:)
    case granularity.to_s
    when "sprints"    then trend_sprints(range)
    when "weeks"      then trend_weeks(range, 1)
    when "fortnights" then trend_weeks(range, 2)
    else trend_months(range)
    end
  end

  # ---------------------------------------------------------------------
  # delivered
  # ---------------------------------------------------------------------

  def delivered
    rows = features_delivered.where.not(ai_estimate_points: nil)
    pr_counts = pr_count_by_key(rows.map(&:jira_key))

    rows.map do |issue|
      {
        key: issue.jira_key,
        title: issue.title,
        dev: user_for_email(issue.assignee_email),
        pts: issue.ai_estimate_points.to_f,
        merged: issue.resolved_at,
        prs: pr_counts[issue.jira_key] || 0
      }
    end
  end

  # ---------------------------------------------------------------------
  # bug_stats (Task 8.2)
  # ---------------------------------------------------------------------

  def bug_stats
    {
      created_this_month: new_bugs_count,
      top_creator: top_creator,
      top_fixer: top_fixer
    }
  end

  private

  # Author with the most BugAttribution rows in this period's project scope
  # (attributions aren't period-scoped themselves — analyzed_at doesn't track
  # a bug's creation date — so this counts across all attributions for the
  # project, same as the "Created the most" stat card in the mock).
  def top_creator
    rows = @project.bug_attributions.where.not(author_name: [ nil, "" ])
                    .group(:author_name).count
    return nil if rows.empty?

    name, count = rows.max_by { |(_, c)| c }
    { name: name, count: count }
  end

  def top_fixer
    counts = delivered_bugs.where.not(assignee_email: [ nil, "" ])
                            .pluck(Arel.sql("LOWER(assignee_email)"))
                            .tally
    return nil if counts.empty?

    top_email, count = counts.max_by { |(_, c)| c }
    name = user_by_email(top_email)&.name || top_email
    { name: name, count: count }
  end

  # ---------------------------------------------------------------------
  # period resolution
  # ---------------------------------------------------------------------

  def resolve_period(period)
    if period.to_s == "sprint"
      sprint = @sprint || active_sprint_for(@project)
      if sprint&.start_date && sprint.end_date
        return [ sprint.start_date.beginning_of_day, sprint.end_date.end_of_day, sprint ]
      end
    end

    # Month period: the selected month (defaults to the current month).
    month = @month || Time.current.beginning_of_month.to_date
    from = month.beginning_of_month.in_time_zone.beginning_of_day
    [ from, month.end_of_month.in_time_zone.end_of_day, nil ]
  end

  # Normalize the requested month to a Date at the 1st, and never allow a month
  # past the current one (no reporting on the future). nil -> current month.
  def clamp_month(month)
    return nil if month.blank?

    date = month.respond_to?(:to_date) ? month.to_date.beginning_of_month : Date.parse(month.to_s).beginning_of_month
    current = Time.current.beginning_of_month.to_date
    date > current ? current : date
  rescue ArgumentError, TypeError
    nil
  end

  def active_sprint_for(project)
    JiraSprint.joins(:jira_board)
               .where(jira_boards: { project_id: project.id })
               .where(state: "active")
               .where.not(start_date: nil).where.not(end_date: nil)
               .order(start_date: :desc)
               .first
  end

  # ---------------------------------------------------------------------
  # delivered_issues scopes (HR boundary: never `tasks` for delivered data)
  # ---------------------------------------------------------------------

  def delivered_in_period
    scope = @project.delivered_issues.where(resolved_at: @from..@to)
    scope = scope.where("LOWER(assignee_email) = ?", @developer.email_address.downcase) if @developer
    scope
  end

  def features_delivered
    delivered_in_period.where.not(issue_type: BUG)
  end

  def delivered_bugs
    delivered_in_period.where(issue_type: BUG)
  end

  def sum_points(scope)
    scope.sum(:ai_estimate_points).to_f
  end

  # ---------------------------------------------------------------------
  # new bugs: union of OPEN tasks Bugs + delivered_issues Bugs by jira_created_at
  # ---------------------------------------------------------------------

  def new_bugs_count
    open_bugs_scope.where(jira_created_at: @from..@to).count +
      @project.delivered_issues.where(issue_type: BUG, jira_created_at: @from..@to).count
  end

  def open_bugs_scope
    @project.tasks.where(issue_type: BUG)
  end

  # ---------------------------------------------------------------------
  # time entries (HR data)
  # ---------------------------------------------------------------------

  def completed_time_entries
    scope = @project.time_entries.completed.in_range(@from, @to)
    scope = scope.where(user_id: @developer.id) if @developer
    scope
  end

  def hours_for(scope)
    scope.sum(:duration_seconds) / 3600.0
  end

  def cost_cents_for(scope)
    scope.sum { |entry| entry.billable_amount_cents }
  end

  # ---------------------------------------------------------------------
  # developers
  # ---------------------------------------------------------------------

  def developer_emails
    return [ @developer.email_address.downcase ] if @developer

    time_entry_emails = @project.time_entries.completed.in_range(@from, @to)
                                 .joins(:user).distinct.pluck("LOWER(users.email_address)")
    delivered_assignee_emails = delivered_in_period.where.not(assignee_email: [ nil, "" ])
                                                    .distinct.pluck(Arel.sql("LOWER(assignee_email)"))
    (time_entry_emails + delivered_assignee_emails).uniq
  end

  def developer_row(email)
    user = user_by_email(email)
    return nil unless user

    entries = @project.time_entries.completed.in_range(@from, @to).where(user_id: user.id)
    {
      user: user,
      name: user.name,
      # SP DONE = complexity of ALL this dev's delivered work (bugs included).
      sp: sum_points(delivered_for_email(email)),
      bugs_fixed: delivered_bugs_for_email(email).count,
      bugs_created: bugs_created_for_email(email, user),
      hours: hours_for(entries),
      cost_cents: cost_cents_for(entries)
    }
  end

  # All delivered issues (any type, incl. bugs) resolved in-period for a dev.
  def delivered_for_email(email)
    @project.delivered_issues.where(resolved_at: @from..@to)
            .where("LOWER(assignee_email) = ?", email)
  end

  def features_delivered_for_email(email)
    @project.delivered_issues.where(resolved_at: @from..@to)
            .where.not(issue_type: BUG)
            .where("LOWER(assignee_email) = ?", email)
  end

  def delivered_bugs_for_email(email)
    @project.delivered_issues.where(resolved_at: @from..@to, issue_type: BUG)
            .where("LOWER(assignee_email) = ?", email)
  end

  # bugs_created (Task 8.2 flip): the count of BugAttribution rows this dev
  # AUTHORED (the AI's origin attribution), not the Jira reporter. Matched by
  # author_email first, falling back to author_name when author_email is
  # blank (the CLI doesn't always resolve an email from git blame). Not
  # period-scoped — attributions don't carry a created-in-period timestamp of
  # their own (analyzed_at is when the AI ran, not when the bug was created) —
  # so this is a project-wide "how many bugs is this dev responsible for"
  # count, matching the "Created the most" stat card.
  #
  # bugs_created_reporter_fallback (below) is Phase 7's original rule (Bugs
  # REPORTED by this email). Kept for reference only — no longer called.
  def bugs_created_for_email(email, user)
    scope = @project.bug_attributions
    by_email = scope.where("LOWER(author_email) = ?", email).count
    return by_email if by_email.positive?
    return 0 unless user

    scope.where("LOWER(author_name) = ?", user.name.to_s.downcase).count
  end

  # bugs_created (Phase 7 reporter-fallback): BugAttribution doesn't exist yet
  # (lands in Phase 8). Until Task 8.2 flips this to attribution counts, count
  # Bugs REPORTED by this email across open `tasks` + `delivered_issues`.
  def bugs_created_reporter_fallback(email)
    open_bugs_scope.where(jira_created_at: @from..@to)
                   .where("LOWER(reporter_email) = ?", email).count +
      @project.delivered_issues.where(issue_type: BUG, jira_created_at: @from..@to)
              .where("LOWER(reporter_email) = ?", email).count
  end

  def user_by_email(email)
    return nil if email.blank?
    @user_cache ||= {}
    @user_cache.fetch(email) { @user_cache[email] = User.find_by("LOWER(email_address) = ?", email) }
  end

  def user_for_email(email)
    return nil if email.blank?
    user_by_email(email.downcase)
  end

  # ---------------------------------------------------------------------
  # trend
  # ---------------------------------------------------------------------

  def trend_base_scope
    scope = @project.delivered_issues
    scope = scope.where("LOWER(assignee_email) = ?", @developer.email_address.downcase) if @developer
    scope
  end

  # Where the trend window ENDS. Stepping back to April must redraw the chart up
  # to 30 April, not up to today — so the series is anchored on the selected
  # period's end rather than on Time.current. The current period is clamped to
  # now, otherwise the current month/sprint would trail empty future buckets.
  def trend_anchor
    now = Time.current
    return now if @to.nil?
    @to > now ? now : @to
  end

  def trend_months(range)
    anchor = trend_anchor
    months = (0...range).map { |i| (anchor.beginning_of_month - i.months) }.reverse
    window_end = anchor.end_of_month.end_of_day

    rows = trend_base_scope.where.not(resolved_at: nil)
                            .where(resolved_at: months.first..window_end)
                            .pluck(:issue_type, :ai_estimate_points, :resolved_at)
    created = bug_created_timestamps(months.first, window_end)

    months.map do |month_start|
      month_end = month_start.end_of_month.end_of_day
      in_month = rows.select { |(_, _, resolved_at)| resolved_at.between?(month_start, month_end) }
      build_point(
        label: month_start.strftime("%b").to_s + " " + month_start.strftime("%y").to_s,
        full: month_start.strftime("%B %Y"),
        rows: in_month,
        bugs_created: created.count { |ts| ts.between?(month_start, month_end) }
      )
    end
  end

  # Week / fortnight buckets, anchored on the Monday of the current week and
  # walking backwards `count` buckets of `weeks_per_bucket` weeks each. Same
  # shape as trend_months — one point per bucket, oldest first.
  def trend_weeks(count, weeks_per_bucket)
    count = [ count.to_i, 1 ].max
    this_week = trend_anchor.beginning_of_week
    starts = (0...count).map { |i| this_week - (i * weeks_per_bucket).weeks }.reverse
    window_end = (this_week + weeks_per_bucket.weeks - 1.second)

    rows = trend_base_scope.where.not(resolved_at: nil)
                            .where(resolved_at: starts.first..window_end)
                            .pluck(:issue_type, :ai_estimate_points, :resolved_at)
    created = bug_created_timestamps(starts.first, window_end)

    starts.map do |bucket_start|
      bucket_end = bucket_start + weeks_per_bucket.weeks - 1.second
      in_bucket = rows.select { |(_, _, resolved_at)| resolved_at.between?(bucket_start, bucket_end) }
      prefix = weeks_per_bucket > 1 ? "Fortnight of" : "Week of"
      build_point(
        label: bucket_start.strftime("%b %-d"),
        full: "#{prefix} #{bucket_start.strftime('%b %-d, %Y')}",
        rows: in_bucket,
        bugs_created: created.count { |ts| ts.between?(bucket_start, bucket_end) }
      )
    end
  end

  def trend_sprints(range)
    sprints = JiraSprint.joins(:jira_board)
                         .where(jira_boards: { project_id: @project.id })
                         .where(state: %w[active closed])
                         .where.not(start_date: nil).where.not(end_date: nil)
                         .where("start_date <= ?", trend_anchor.to_date)
                         .order(start_date: :asc)
                         .to_a
                         .last(range)

    all_rows = trend_base_scope.where.not(resolved_at: nil).pluck(:issue_type, :ai_estimate_points, :resolved_at)
    created = sprints.any? ? bug_created_timestamps(sprints.first.start_date.beginning_of_day,
                                                     sprints.last.end_date.end_of_day) : []

    sprints.map do |sprint|
      window = sprint.start_date.beginning_of_day..sprint.end_date.end_of_day
      in_sprint = all_rows.select { |(_, _, resolved_at)| window.cover?(resolved_at) }
      build_point(label: sprint.name, full: sprint.name, rows: in_sprint,
                  bugs_created: created.count { |ts| window.cover?(ts) })
    end
  end

  # Bugs *opened* (by jira_created_at) across both open tasks and delivered
  # issues in the window — the "created" trend series, distinct from the
  # "fixed" (resolved) series which reads delivered_issues by resolved_at.
  # Developer-scoped by assignee_email to match the rest of the trend.
  def bug_created_timestamps(from, to)
    open_scope = open_bugs_scope
    delivered_scope = @project.delivered_issues.where(issue_type: BUG)
    if @developer
      email = @developer.email_address.downcase
      open_scope = open_scope.where("LOWER(assignee_email) = ?", email)
      delivered_scope = delivered_scope.where("LOWER(assignee_email) = ?", email)
    end
    (open_scope.where(jira_created_at: from..to).pluck(:jira_created_at) +
     delivered_scope.where(jira_created_at: from..to).pluck(:jira_created_at)).compact
  end

  def build_point(label:, full:, rows:, bugs_created:)
    bugs_fixed = rows.count { |(issue_type, _, _)| issue_type == BUG }
    {
      label: label,
      full: full,
      # SP trend counts ALL delivered work by complexity (bugs included).
      sp: rows.sum { |(_, points, _)| points.to_f },
      bugs_created: bugs_created,
      bugs_fixed: bugs_fixed
    }
  end

  # ---------------------------------------------------------------------
  # PR counts for the delivered table
  # ---------------------------------------------------------------------

  def pr_count_by_key(keys)
    return {} if keys.empty?

    counts = Hash.new(0)
    @project.workspace.pr_reviews.pluck(:pr_branch, :pr_title).each do |branch, title|
      key = PrJiraKey.extract(branch: branch, title: title, body: nil)
      counts[key] += 1 if key && keys.include?(key)
    end
    counts
  end
end
