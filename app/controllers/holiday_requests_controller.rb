class HolidayRequestsController < ApplicationController
  include WorkspaceScoped

  before_action { require_product!(:time_hr) }

  before_action :require_employee!
  before_action :require_admin!, only: [:approve, :cancel]
  before_action :set_holiday_request, only: [:approve, :cancel]

  def index
    @balance = current_user.holiday_balance(current_workspace)

    if current_user.admin_or_owner?(current_workspace)
      @pending_requests = current_workspace.holiday_requests
        .pending
        .includes(:user)
        .order(start_date: :asc)
      @all_requests = current_workspace.holiday_requests
        .includes(:user, :reviewed_by)
        .order(start_date: :desc)
    end

    @my_requests = current_user.holiday_requests
      .where(workspace: current_workspace)
      .order(start_date: :desc)

    @team_upcoming = upcoming_team_holidays
  end

  def new
    @holiday_request = current_workspace.holiday_requests.build(user: current_user)
    @balance = current_user.holiday_balance(current_workspace)
  end

  def create
    @holiday_request = current_workspace.holiday_requests.build(holiday_request_params)
    @holiday_request.user = current_user

    if @holiday_request.save
      redirect_to holiday_requests_path, notice: "Time off request submitted."
    else
      @balance = current_user.holiday_balance(current_workspace)
      render :new, status: :unprocessable_entity
    end
  end

  def approve
    @holiday_request.approve!(current_user)
    redirect_to holiday_requests_path, notice: "Request approved."
  end

  def cancel
    @holiday_request.cancel!(current_user)
    redirect_to holiday_requests_path, notice: "Request cancelled."
  end

  private

  def set_holiday_request
    @holiday_request = current_workspace.holiday_requests.find(params[:id])
  end

  def holiday_request_params
    params.require(:holiday_request).permit(:start_date, :end_date, :note)
  end

  def upcoming_team_holidays
    project_ids = current_user.project_memberships
      .joins(:project)
      .where(projects: { workspace_id: current_workspace.id })
      .pluck(:project_id)

    teammate_ids = ProjectMembership
      .where(project_id: project_ids)
      .where.not(user_id: current_user.id)
      .distinct
      .pluck(:user_id)

    HolidayRequest
      .where(workspace: current_workspace, user_id: teammate_ids, status: :approved)
      .where("end_date >= ?", Date.current)
      .includes(:user)
      .order(start_date: :asc)
  end
end
