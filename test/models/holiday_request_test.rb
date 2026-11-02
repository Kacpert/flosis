require "test_helper"

class HolidayRequestTest < ActiveSupport::TestCase
  include ActionMailer::TestHelper

  test "valid request with all fields" do
    request = HolidayRequest.new(
      user: users(:one),
      workspace: workspaces(:one),
      start_date: Date.new(2026, 8, 3),
      end_date: Date.new(2026, 8, 5),
      note: "Vacation"
    )
    assert request.valid?, request.errors.full_messages.inspect
    assert_equal 3, request.business_days
  end

  test "computes business_days excluding weekends" do
    # Monday May 4 to Friday May 8, 2026 = 5 business days
    request = HolidayRequest.new(
      user: users(:one),
      workspace: workspaces(:one),
      start_date: Date.new(2026, 5, 4),
      end_date: Date.new(2026, 5, 8)
    )
    request.valid?
    assert_equal 5, request.business_days
  end

  test "computes business_days for range spanning weekend" do
    # Monday May 4 to Monday May 11, 2026 = 6 business days (skip Sat 9, Sun 10)
    request = HolidayRequest.new(
      user: users(:one),
      workspace: workspaces(:one),
      start_date: Date.new(2026, 5, 4),
      end_date: Date.new(2026, 5, 11)
    )
    request.valid?
    assert_equal 6, request.business_days
  end

  test "single day request" do
    request = HolidayRequest.new(
      user: users(:one),
      workspace: workspaces(:one),
      start_date: Date.new(2026, 5, 4),
      end_date: Date.new(2026, 5, 4)
    )
    request.valid?
    assert_equal 1, request.business_days
  end

  test "invalid when start_date after end_date" do
    request = HolidayRequest.new(
      user: users(:one),
      workspace: workspaces(:one),
      start_date: Date.new(2026, 5, 8),
      end_date: Date.new(2026, 5, 4)
    )
    assert_not request.valid?
    assert_includes request.errors[:end_date], "must be on or after start date"
  end

  test "invalid when start_date in the past on create" do
    request = HolidayRequest.new(
      user: users(:one),
      workspace: workspaces(:one),
      start_date: 1.day.ago.to_date,
      end_date: Date.current
    )
    assert_not request.valid?
    assert_includes request.errors[:start_date], "can't be in the past"
  end

  test "invalid when overlapping with existing pending request" do
    existing = holiday_requests(:kacper_pending) # May 4-8
    request = HolidayRequest.new(
      user: users(:one),
      workspace: workspaces(:one),
      start_date: Date.new(2026, 5, 6),
      end_date: Date.new(2026, 5, 12)
    )
    assert_not request.valid?
    assert_includes request.errors[:base], "overlaps with an existing request"
  end

  test "invalid when overlapping with existing approved request" do
    existing = holiday_requests(:kacper_approved) # Jul 1-3
    request = HolidayRequest.new(
      user: users(:one),
      workspace: workspaces(:one),
      start_date: Date.new(2026, 7, 2),
      end_date: Date.new(2026, 7, 4)
    )
    assert_not request.valid?
    assert_includes request.errors[:base], "overlaps with an existing request"
  end

  test "valid when overlapping with cancelled request" do
    cancelled = holiday_requests(:kacper_pending)
    cancelled.update_column(:status, 2) # cancelled
    request = HolidayRequest.new(
      user: users(:one),
      workspace: workspaces(:one),
      start_date: Date.new(2026, 5, 6),
      end_date: Date.new(2026, 5, 12)
    )
    assert request.valid?
  end

  test "invalid when insufficient balance" do
    user = users(:two)
    workspace = workspaces(:one)
    # other_user has 10 days balance (from fixture), but pending request for 5 already
    # Request 6 more days — balance is 10, but 5 are pending, so effective = 5
    request = HolidayRequest.new(
      user: user,
      workspace: workspace,
      start_date: 2.months.from_now.beginning_of_week.to_date,
      end_date: 2.months.from_now.beginning_of_week.to_date + 7.days,
      note: "Too many days"
    )
    assert_not request.valid?
    assert_includes request.errors[:base].join, "insufficient holiday balance"
  end

  test "status enum values" do
    assert_equal 0, HolidayRequest.statuses[:pending]
    assert_equal 1, HolidayRequest.statuses[:approved]
    assert_equal 2, HolidayRequest.statuses[:cancelled]
  end

  test "approve! creates deduction entry and sends email" do
    request = holiday_requests(:kacper_pending)
    admin = users(:one)

    assert_difference "HolidayBalanceEntry.count", 1 do
      assert_emails 1 do
        request.approve!(admin)
      end
    end

    assert request.approved?
    assert_equal admin, request.reviewed_by
    assert_not_nil request.reviewed_at

    entry = request.holiday_balance_entries.last
    assert_equal "deduction", entry.entry_type
    assert_equal(-request.business_days, entry.days)
  end

  test "cancel! pending request does not create reversal" do
    request = holiday_requests(:kacper_pending)
    admin = users(:one)

    assert_no_difference "HolidayBalanceEntry.count" do
      assert_emails 1 do
        request.cancel!(admin)
      end
    end

    assert request.cancelled?
    assert_equal admin, request.reviewed_by
  end

  test "cancel! approved request creates reversal entry" do
    request = holiday_requests(:kacper_approved)
    admin = users(:one)
    # First add a deduction so there's something to reverse
    request.holiday_balance_entries.create!(
      user: request.user,
      workspace: request.workspace,
      entry_type: :deduction,
      days: -request.business_days
    )

    assert_difference "HolidayBalanceEntry.count", 1 do
      assert_emails 1 do
        request.cancel!(admin)
      end
    end

    assert request.cancelled?
    reversal = request.holiday_balance_entries.reversal.last
    assert_equal request.business_days, reversal.days
  end
end
