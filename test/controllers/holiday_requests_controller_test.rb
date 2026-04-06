require "test_helper"

class HolidayRequestsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as(users(:one))
  end

  test "index shows holiday requests" do
    get holiday_requests_path
    assert_response :success
  end

  test "index as employee shows own requests" do
    sign_in_as(users(:two))
    get holiday_requests_path
    assert_response :success
  end

  test "new shows request form" do
    get new_holiday_request_path
    assert_response :success
  end

  test "create with valid params" do
    start_date = 2.months.from_now.beginning_of_week.to_date
    end_date = start_date + 4.days

    assert_difference "HolidayRequest.count", 1 do
      post holiday_requests_path, params: {
        holiday_request: {
          start_date: start_date,
          end_date: end_date,
          note: "Vacation time"
        }
      }
    end
    assert_redirected_to holiday_requests_path
  end

  test "create with insufficient balance shows error" do
    # User one has 35 days balance, request way too many
    start_date = 3.months.from_now.beginning_of_week.to_date
    end_date = start_date + 200.days

    assert_no_difference "HolidayRequest.count" do
      post holiday_requests_path, params: {
        holiday_request: {
          start_date: start_date,
          end_date: end_date,
          note: "Too long"
        }
      }
    end
    assert_response :unprocessable_entity
  end

  test "approve as admin" do
    request = holiday_requests(:other_user_pending)

    patch approve_holiday_request_path(request)
    assert_redirected_to holiday_requests_path

    request.reload
    assert request.approved?
    assert_equal users(:one), request.reviewed_by
  end

  test "approve requires admin" do
    sign_in_as(users(:two)) # employee
    request = holiday_requests(:kacper_pending)

    patch approve_holiday_request_path(request)
    assert_redirected_to root_path
  end

  test "cancel as admin" do
    request = holiday_requests(:other_user_pending)

    patch cancel_holiday_request_path(request)
    assert_redirected_to holiday_requests_path

    request.reload
    assert request.cancelled?
  end

  test "cancel requires admin" do
    sign_in_as(users(:two)) # employee
    request = holiday_requests(:kacper_pending)

    patch cancel_holiday_request_path(request)
    assert_redirected_to root_path
  end
end
