require "test_helper"

class FeedbackMeetingsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @admin = users(:one)
    @employee = users(:two)
    @meeting = feedback_meetings(:one)
    @visible_meeting = feedback_meetings(:visible_notes)
  end

  # --- Admin tests ---

  test "admin can list all meetings" do
    sign_in_as(@admin)
    get feedback_meetings_path
    assert_response :success
  end

  test "admin can view any meeting" do
    sign_in_as(@admin)
    get feedback_meeting_path(@meeting)
    assert_response :success
  end

  test "admin can see notes regardless of notes_visible" do
    sign_in_as(@admin)
    get feedback_meeting_path(@meeting)
    assert_response :success
    assert_match "Great performance this quarter", response.body
  end

  test "admin can access new meeting form" do
    sign_in_as(@admin)
    get new_feedback_meeting_path
    assert_response :success
  end

  test "admin can create a meeting" do
    sign_in_as(@admin)
    assert_difference "FeedbackMeeting.count", 1 do
      post feedback_meetings_path, params: {
        feedback_meeting: {
          employee_id: @employee.id,
          title: "New Feedback Meeting",
          scheduled_at: 5.days.from_now,
          notes: "Discussion points",
          notes_visible: false
        }
      }
    end
    assert_redirected_to feedback_meetings_path
  end

  test "admin can access edit form" do
    sign_in_as(@admin)
    get edit_feedback_meeting_path(@meeting)
    assert_response :success
  end

  test "admin can update a meeting" do
    sign_in_as(@admin)
    patch feedback_meeting_path(@meeting), params: {
      feedback_meeting: { title: "Updated Title" }
    }
    assert_redirected_to feedback_meeting_path(@meeting)
    assert_equal "Updated Title", @meeting.reload.title
  end

  test "admin can toggle notes_visible" do
    sign_in_as(@admin)
    patch feedback_meeting_path(@meeting), params: {
      feedback_meeting: { notes_visible: true }
    }
    assert @meeting.reload.notes_visible
  end

  test "admin can destroy a meeting" do
    sign_in_as(@admin)
    assert_difference "FeedbackMeeting.count", -1 do
      delete feedback_meeting_path(@meeting)
    end
    assert_redirected_to feedback_meetings_path
  end

  # --- Employee tests ---

  test "employee can list only their meetings" do
    sign_in_as(@employee)
    get feedback_meetings_path
    assert_response :success
  end

  test "employee can view their own meeting" do
    sign_in_as(@employee)
    get feedback_meeting_path(@meeting)
    assert_response :success
  end

  test "employee cannot see notes when notes_visible is false" do
    sign_in_as(@employee)
    get feedback_meeting_path(@meeting)
    assert_response :success
    assert_no_match "Great performance this quarter", response.body
  end

  test "employee can see notes when notes_visible is true" do
    sign_in_as(@employee)
    get feedback_meeting_path(@visible_meeting)
    assert_response :success
    assert_match "Set goals for next quarter", response.body
  end

  test "employee cannot access new meeting form" do
    sign_in_as(@employee)
    get new_feedback_meeting_path
    assert_redirected_to root_path
  end

  test "employee cannot create a meeting" do
    sign_in_as(@employee)
    assert_no_difference "FeedbackMeeting.count" do
      post feedback_meetings_path, params: {
        feedback_meeting: {
          employee_id: @employee.id,
          title: "Unauthorized",
          scheduled_at: 5.days.from_now
        }
      }
    end
    assert_redirected_to root_path
  end

  test "employee cannot edit a meeting" do
    sign_in_as(@employee)
    get edit_feedback_meeting_path(@meeting)
    assert_redirected_to root_path
  end

  test "employee cannot update a meeting" do
    sign_in_as(@employee)
    patch feedback_meeting_path(@meeting), params: {
      feedback_meeting: { title: "Hacked" }
    }
    assert_redirected_to root_path
    assert_not_equal "Hacked", @meeting.reload.title
  end

  test "employee cannot destroy a meeting" do
    sign_in_as(@employee)
    assert_no_difference "FeedbackMeeting.count" do
      delete feedback_meeting_path(@meeting)
    end
    assert_redirected_to root_path
  end
end
