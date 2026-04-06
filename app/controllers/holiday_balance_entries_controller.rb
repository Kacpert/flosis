class HolidayBalanceEntriesController < ApplicationController
  include WorkspaceScoped

  before_action :require_employee!
  before_action :require_admin!, only: [:new, :create]

  def index
    if current_user.admin_or_owner?(current_workspace) && params[:user_id].present?
      @target_user = User.find(params[:user_id])
    else
      @target_user = current_user
    end

    @entries = HolidayBalanceEntry
      .where(user: @target_user, workspace: current_workspace)
      .includes(:created_by, :holiday_request)
      .order(created_at: :desc)

    @balance = @target_user.holiday_balance(current_workspace)

    if params[:year].present?
      year = params[:year].to_i
      @entries = @entries.where(created_at: Date.new(year)..Date.new(year).end_of_year)
    end
  end

  def new
    @target_user = User.find(params[:user_id])
    @entry = HolidayBalanceEntry.new
    @balance = @target_user.holiday_balance(current_workspace)
  end

  def create
    @target_user = User.find(entry_params[:user_id])
    @entry = HolidayBalanceEntry.new(
      user: @target_user,
      workspace: current_workspace,
      entry_type: :admin_adjustment,
      days: entry_params[:days],
      note: entry_params[:note],
      created_by: current_user
    )

    if @entry.save
      redirect_to holiday_balance_entries_path(user_id: @target_user.id),
        notice: "Balance adjusted by #{@entry.days} days."
    else
      @balance = @target_user.holiday_balance(current_workspace)
      render :new, status: :unprocessable_entity
    end
  end

  private

  def entry_params
    params.require(:holiday_balance_entry).permit(:user_id, :days, :note)
  end
end
