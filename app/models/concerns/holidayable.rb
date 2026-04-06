module Holidayable
  extend ActiveSupport::Concern

  included do
    has_many :holiday_requests
    has_many :holiday_balance_entries
  end

  def holiday_balance(workspace)
    holiday_balance_entries.where(workspace: workspace).sum(:days)
  end
end
