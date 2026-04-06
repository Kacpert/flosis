class HolidayYearlyGrantJob < ApplicationJob
  queue_as :default

  def perform
    year = Date.current.year

    WorkspaceMembership.where(role: [:employee, :admin, :owner]).includes(:user, :workspace).find_each do |membership|
      already_granted = HolidayBalanceEntry.exists?(
        user: membership.user,
        workspace: membership.workspace,
        entry_type: :yearly_grant,
        created_at: Date.new(year).beginning_of_year..Date.new(year).end_of_year
      )

      next if already_granted

      HolidayBalanceEntry.create!(
        user: membership.user,
        workspace: membership.workspace,
        entry_type: :yearly_grant,
        days: 20,
        note: "Annual holiday grant for #{year}"
      )
    end
  end
end
