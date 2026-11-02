require "test_helper"

class HolidayBalanceEntriesControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as(users(:one)) # owner/admin
  end

  test "index shows balance entries for a user" do
    get holiday_balance_entries_path(user_id: users(:one).id)
    assert_response :success
  end

  test "index for own entries as employee" do
    sign_in_as(users(:two))
    get holiday_balance_entries_path
    assert_response :success
  end

  test "new shows adjustment form for admin" do
    get new_holiday_balance_entry_path(user_id: users(:two).id)
    assert_response :success
  end

  test "new requires admin" do
    sign_in_as(users(:two))
    get new_holiday_balance_entry_path(user_id: users(:one).id)
    assert_redirected_to root_path
  end

  test "create admin adjustment" do
    assert_difference "HolidayBalanceEntry.count", 1 do
      post holiday_balance_entries_path, params: {
        holiday_balance_entry: {
          user_id: users(:two).id,
          days: 5,
          note: "Bonus days for extra work"
        }
      }
    end
    assert_redirected_to holiday_balance_entries_path(user_id: users(:two).id)

    entry = HolidayBalanceEntry.last
    assert_equal "admin_adjustment", entry.entry_type
    assert_equal 5, entry.days
    assert_equal users(:one), entry.created_by
  end

  test "create requires admin" do
    sign_in_as(users(:two))
    assert_no_difference "HolidayBalanceEntry.count" do
      post holiday_balance_entries_path, params: {
        holiday_balance_entry: {
          user_id: users(:one).id,
          days: 5,
          note: "Trying to hack"
        }
      }
    end
    assert_redirected_to root_path
  end

  test "create with missing note fails" do
    assert_no_difference "HolidayBalanceEntry.count" do
      post holiday_balance_entries_path, params: {
        holiday_balance_entry: {
          user_id: users(:two).id,
          days: 5,
          note: ""
        }
      }
    end
    assert_response :unprocessable_entity
  end
end
