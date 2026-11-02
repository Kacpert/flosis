require "test_helper"

class Hidmin::UsersControllerTest < ActionDispatch::IntegrationTest
  setup do
    users(:one).update!(flosis_staff: true)
    sign_in_as(users(:one))
  end

  test "people are searched by name or email" do
    get hidmin_users_path, params: { q: "other" }

    assert_response :success
    assert_includes response.body, users(:two).email_address
    assert_not_includes response.body, users(:client_user).email_address
  end

  test "a name, an address and staff access are saved" do
    patch hidmin_user_path(users(:two)), params: { user: { name: "Renamed", email_address: "renamed@example.com", flosis_staff: "1" } }

    assert_redirected_to hidmin_user_path(users(:two))
    users(:two).reload
    assert_equal "Renamed", users(:two).name
    assert_equal "renamed@example.com", users(:two).email_address
    assert users(:two).flosis_staff?
  end

  test "an invalid address is shown back, not saved" do
    patch hidmin_user_path(users(:two)), params: { user: { email_address: "nope" } }

    assert_response :unprocessable_entity
    assert_equal "two@example.com", users(:two).reload.email_address
  end

  test "staff can't take staff access away from themselves" do
    patch hidmin_user_path(users(:one)), params: { user: { flosis_staff: "0" } }

    assert_redirected_to hidmin_user_path(users(:one))
    assert users(:one).reload.flosis_staff?
  end
end
