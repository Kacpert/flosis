require "test_helper"

class FeedbackMeetingTest < ActiveSupport::TestCase
  test "valid feedback meeting" do
    meeting = feedback_meetings(:one)
    assert meeting.valid?
  end

  test "requires title" do
    meeting = feedback_meetings(:one)
    meeting.title = nil
    assert_not meeting.valid?
    assert_includes meeting.errors[:title], "can't be blank"
  end

  test "requires scheduled_at" do
    meeting = feedback_meetings(:one)
    meeting.scheduled_at = nil
    assert_not meeting.valid?
    assert_includes meeting.errors[:scheduled_at], "can't be blank"
  end

  test "requires workspace" do
    meeting = feedback_meetings(:one)
    meeting.workspace = nil
    assert_not meeting.valid?
  end

  test "requires creator" do
    meeting = feedback_meetings(:one)
    meeting.creator = nil
    assert_not meeting.valid?
  end

  test "requires employee" do
    meeting = feedback_meetings(:one)
    meeting.employee = nil
    assert_not meeting.valid?
  end

  test "for_employee scope returns only that employee's meetings" do
    employee = users(:two)
    meetings = FeedbackMeeting.for_employee(employee)
    assert meetings.all? { |m| m.employee_id == employee.id }
  end

  test "belongs to workspace" do
    meeting = feedback_meetings(:one)
    assert_equal workspaces(:one), meeting.workspace
  end

  test "belongs to creator" do
    meeting = feedback_meetings(:one)
    assert_equal users(:one), meeting.creator
  end

  test "belongs to employee" do
    meeting = feedback_meetings(:one)
    assert_equal users(:two), meeting.employee
  end

  test "default ordering is by scheduled_at descending" do
    meetings = FeedbackMeeting.recent
    dates = meetings.map(&:scheduled_at)
    assert_equal dates, dates.sort.reverse
  end
end
