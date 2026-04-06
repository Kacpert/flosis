class FeedbackMeetingsController < ApplicationController
  include WorkspaceScoped

  before_action :require_admin!, only: %i[new create edit update destroy]
  before_action :set_feedback_meeting, only: %i[show edit update destroy]
  before_action :set_employees, only: %i[new create edit update]

  def index
    @feedback_meetings = scoped_meetings.recent.includes(:employee, :creator)
  end

  def show
    @show_notes = current_user.admin_or_owner?(current_workspace) || @feedback_meeting.notes_visible
  end

  def new
    @feedback_meeting = current_workspace.feedback_meetings.build
  end

  def create
    @feedback_meeting = current_workspace.feedback_meetings.build(feedback_meeting_params)
    @feedback_meeting.creator = current_user

    if @feedback_meeting.save
      redirect_to feedback_meetings_path, notice: "Feedback meeting created."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    if @feedback_meeting.update(feedback_meeting_params)
      redirect_to feedback_meeting_path(@feedback_meeting), notice: "Feedback meeting updated."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @feedback_meeting.destroy
    redirect_to feedback_meetings_path, notice: "Feedback meeting deleted.", status: :see_other
  end

  private

  def scoped_meetings
    if current_user.admin_or_owner?(current_workspace)
      current_workspace.feedback_meetings
    else
      current_workspace.feedback_meetings.for_employee(current_user)
    end
  end

  def set_feedback_meeting
    @feedback_meeting = scoped_meetings.find(params[:id])
  end

  def set_employees
    @employees = current_workspace.workspace_memberships
      .where(role: [:employee, :admin, :owner])
      .includes(:user)
      .map { |m| [m.user.name, m.user.id] }
  end

  def feedback_meeting_params
    params.require(:feedback_meeting).permit(:title, :scheduled_at, :employee_id, :notes, :notes_visible)
  end
end
