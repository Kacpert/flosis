require "test_helper"

class Hidmin::AccessTest < ActionDispatch::IntegrationTest
  test "signed out, it asks to sign in" do
    get hidmin_root_path
    assert_redirected_to new_session_path
  end

  test "a workspace admin who isn't Flosis staff gets a 404 everywhere" do
    sign_in_as(users(:one))

    pages.each do |path|
      get path
      assert_response :not_found, path
    end
    post hidmin_workspaces_path, params: { workspace: { name: "Sneaky" }, admin: { name: "X", email_address: "x@example.com" } }
    assert_response :not_found
    assert_not Workspace.exists?(name: "Sneaky")
  end

  test "Flosis staff open every page" do
    users(:one).update!(flosis_staff: true)
    sign_in_as(users(:one))

    pages.each do |path|
      get path
      assert_response :success, path
    end
  end

  private

  def pages
    [ hidmin_root_path, hidmin_workspaces_path, hidmin_workspace_path(workspaces(:one)),
      new_hidmin_workspace_path, hidmin_users_path, hidmin_user_path(users(:two)) ]
  end
end
