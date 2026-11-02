# Computes the monthly report figures for one project. Pure read model.
class ProjectMonthlyReport
  CUSTOMER_ACCEPTANCE_STATUS = "Customer Acceptance".freeze
  BUG_ISSUE_TYPE = "Bug".freeze

  def initialize(project:, month:)
    @project = project
    @from = month.beginning_of_month.beginning_of_day
    @to = month.end_of_month.end_of_day
  end

  def total_seconds
    completed_entries.sum(:duration_seconds)
  end

  def per_user_hours
    total = total_seconds.to_f
    completed_entries
      .joins(:user)
      .group("users.id")
      .sum(:duration_seconds)
      .map { |user_id, seconds| { user: User.find(user_id), seconds: seconds,
                                  percent: total.zero? ? 0.0 : (seconds / total * 100).round(1) } }
      .sort_by { |row| -row[:seconds] }
  end

  def customer_acceptance_count
    jira_tasks.where(jira_status_name: CUSTOMER_ACCEPTANCE_STATUS)
              .where(jira_updated_at: @from..@to).count
  end

  def bugs_count
    jira_tasks.where(issue_type: BUG_ISSUE_TYPE)
              .where(jira_updated_at: @from..@to).count
  end

  private

  def completed_entries
    @project.time_entries.completed.in_range(@from, @to)
  end

  def jira_tasks
    @project.tasks.jira_synced
  end
end
