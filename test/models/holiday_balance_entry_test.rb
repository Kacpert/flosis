require "test_helper"

class HolidayBalanceEntryTest < ActiveSupport::TestCase
  test "valid entry with all required fields" do
    entry = HolidayBalanceEntry.new(
      user: users(:one),
      workspace: workspaces(:one),
      entry_type: :admin_adjustment,
      days: 5,
      note: "Extra days for Q4"
    )
    assert entry.valid?
  end

  test "invalid without days" do
    entry = HolidayBalanceEntry.new(
      user: users(:one),
      workspace: workspaces(:one),
      entry_type: :yearly_grant
    )
    assert_not entry.valid?
    assert_includes entry.errors[:days], "can't be blank"
  end

  test "invalid with zero days" do
    entry = HolidayBalanceEntry.new(
      user: users(:one),
      workspace: workspaces(:one),
      entry_type: :yearly_grant,
      days: 0
    )
    assert_not entry.valid?
  end

  test "admin_adjustment requires note" do
    entry = HolidayBalanceEntry.new(
      user: users(:one),
      workspace: workspaces(:one),
      entry_type: :admin_adjustment,
      days: 5,
      note: nil
    )
    assert_not entry.valid?
    assert_includes entry.errors[:note], "is required for admin adjustments"
  end

  test "yearly_grant does not require note" do
    entry = HolidayBalanceEntry.new(
      user: users(:one),
      workspace: workspaces(:one),
      entry_type: :yearly_grant,
      days: 20
    )
    assert entry.valid?
  end

  test "entry_type enum values" do
    assert_equal 0, HolidayBalanceEntry.entry_types[:yearly_grant]
    assert_equal 1, HolidayBalanceEntry.entry_types[:admin_adjustment]
    assert_equal 2, HolidayBalanceEntry.entry_types[:deduction]
    assert_equal 3, HolidayBalanceEntry.entry_types[:reversal]
  end

  test "user holiday_balance sums all entries for workspace" do
    user = users(:one)
    workspace = workspaces(:one)
    # Fixtures: kacper_initial_grant (15) + kacper_yearly_grant (20) = 35
    assert_equal 35, user.holiday_balance(workspace)
  end

  test "user holiday_balance returns 0 with no entries" do
    user = users(:two)
    workspace = workspaces(:two)
    assert_equal 0, user.holiday_balance(workspace)
  end
end
