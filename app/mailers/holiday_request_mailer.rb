class HolidayRequestMailer < ApplicationMailer
  def approved(holiday_request)
    @holiday_request = holiday_request
    @user = holiday_request.user
    @reviewer = holiday_request.reviewed_by
    mail(
      to: @user.email_address,
      subject: "Your time off request has been approved"
    )
  end

  def cancelled(holiday_request)
    @holiday_request = holiday_request
    @user = holiday_request.user
    @reviewer = holiday_request.reviewed_by
    mail(
      to: @user.email_address,
      subject: "Your time off request has been cancelled"
    )
  end
end
