# What an organization's month was measured against: the plan and its price,
# frozen once the month closes (SCRUM-70). The current month's row follows a
# plan assigned or edited during it; a closed month's row is never touched, so
# October keeps "of $1,200" whatever the plan says now.
class AiMonthLimit < ApplicationRecord
  belongs_to :workspace
  belongs_to :ai_plan, optional: true

  validates :month, presence: true, uniqueness: { scope: :workspace_id }

  # This month's row from the plan that stands now, if there is none yet. Every
  # recorded run calls it, so each month with runs has a row.
  def self.ensure_current!(workspace)
    month = Date.current.beginning_of_month
    return if exists?(workspace: workspace, month: month)

    create!(workspace: workspace, month: month, **from_plan(workspace))
  rescue ActiveRecord::RecordNotUnique
    nil
  end

  # This month's row brought in line with the plan that stands now: a plan
  # assigned, or a plan's name or price edited.
  def self.refresh_current!(workspace)
    row = find_or_initialize_by(workspace: workspace, month: Date.current.beginning_of_month)
    row.update!(from_plan(workspace))
    row
  end

  # The month's row; for the current month without one yet, an unsaved row from
  # the live plan. A past month without a row had no runs to measure.
  def self.for(workspace, month)
    month = month.to_date.beginning_of_month
    find_by(workspace: workspace, month: month) ||
      (month == Date.current.beginning_of_month ? new(workspace: workspace, month: month, **from_plan(workspace)) : nil)
  end

  # SCRUM-71: a month a plan was paid for is measured against what was paid:
  # the plan charge (prorated from starts_on in a first month), plus each
  # upgrade's difference (add: true). Repricing the plan never moves it.
  def self.paid!(workspace, month:, plan:, limit_usd:, starts_on: nil, add: false)
    row = find_or_initialize_by(workspace: workspace, month: month.beginning_of_month)
    row.limit_usd = add && row.persisted? ? row.limit_usd.to_d + limit_usd : limit_usd
    row.ai_plan = plan
    row.plan_name = plan&.name
    row.starts_on = starts_on && starts_on > row.month ? starts_on : nil unless add
    row.save!
    row
  rescue ActiveRecord::RecordNotUnique
    retry
  end

  def partial?
    starts_on.present? && starts_on > month
  end

  def self.from_plan(workspace)
    plan = workspace.ai_plan
    { ai_plan: plan, plan_name: plan&.name, limit_usd: plan&.monthly_price_usd }
  end
  private_class_method :from_plan
end
