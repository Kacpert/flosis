require "test_helper"

class HolidayRequestMailerTest < ActionMailer::TestCase
  test "approved email" do
    request = holiday_requests(:kacper_pending)
    request.update_columns(status: 1, reviewed_by_id: users(:one).id, reviewed_at: Time.current)

    mail = HolidayRequestMailer.approved(request)

    assert_equal "Your time off request has been approved", mail.subject
    assert_equal [request.user.email_address], mail.to
    assert_match "May 4", mail.body.encoded
    assert_match "May 8", mail.body.encoded
    assert_match "5 days", mail.body.encoded
  end

  test "cancelled email" do
    request = holiday_requests(:kacper_approved)
    request.update_columns(status: 2, reviewed_by_id: users(:one).id, reviewed_at: Time.current)

    mail = HolidayRequestMailer.cancelled(request)

    assert_equal "Your time off request has been cancelled", mail.subject
    assert_equal [request.user.email_address], mail.to
    assert_match "Jul 1", mail.body.encoded
    assert_match "Jul 3", mail.body.encoded
  end
end
