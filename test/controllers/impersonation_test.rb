require "test_helper"

# The impersonation escape hatch. An administrator who is "viewing as" someone
# else must always be able to get their own session back, and must not leave a
# dangling admin_session_id behind if they log out instead — a cookie with no
# live session takes the layout's banner into a nil current_user. The cookie is
# signed, so these assert on the behaviour it drives rather than its contents.
class ImpersonationTest < ActionDispatch::IntegrationTest
  setup do
    workspace_memberships(:one_owner).update!(workspace_admin: true)
    sign_in_as(users(:one))
    @admin_session = Current.session
    @member = workspace_memberships(:two_employee)
  end

  test "impersonating a member stashes the administrator's session and switches identity" do
    post become_workspace_member_path(@member)

    assert_redirected_to root_path
    assert cookies[:admin_session_id].present?

    get time_entries_path

    assert_response :success
    assert_match "Viewing as", response.body
    assert_match users(:two).name, response.body
  end

  test "stopping impersonation restores the administrator's own session and clears the cookie" do
    post become_workspace_member_path(@member)

    # No new Session row: the stashed session is resumed, not re-created. A
    # fresh login here would look the same from every other angle.
    assert_no_difference "Session.count" do
      post stop_impersonating_path
    end

    assert_redirected_to workspace_members_path
    assert cookies[:admin_session_id].blank?
    assert Session.exists?(@admin_session.id)

    # The directory is administrator-only, so reaching it proves the session now
    # in play is the administrator's and not the impersonated member's.
    get workspace_members_path

    assert_response :success
    assert_no_match(/Viewing as/, response.body)
  end

  test "logging out while impersonating clears the escape-hatch cookie" do
    post become_workspace_member_path(@member)

    delete session_path

    assert cookies[:admin_session_id].blank?

    follow_redirect!

    assert_response :success
  end
end
