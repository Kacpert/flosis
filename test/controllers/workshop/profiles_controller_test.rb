require "test_helper"

# Profile Settings inside Flosis (designs/admin/profile.html and its states):
# the Flosis shell, the profile form, the AI costs card with the Workshop
# switch, and Your access. Time & HR keeps its own /profile.
class Workshop::ProfilesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @workspace = workspaces(:one)
    @workspace.update!(workshop_enabled: true)
    @user = users(:one)
    sign_in_as(@user)
    post switch_product_path, params: { product: "workshop" }
  end

  test "Profile Settings is drawn in the Flosis shell, not Time & HR" do
    get workshop_profile_path
    assert_response :success

    assert_select "h1", "Profile Settings"
    assert_select "[data-clar-dropdown-target=panel]"
    assert_select ".m3-card-elevated", count: 0
    assert_select "form[action=?]", workshop_profile_path do
      assert_select "input[name=?]", "user[name]"
      assert_select "input[name=?]", "user[email_address]"
      assert_select "select[name=?]", "user[timezone]"
      assert_select "input[name=?][type=password]", "user[current_password]"
      assert_select "input[name=?][type=password]", "user[password]"
      assert_select "input[name=?][type=password]", "user[password_confirmation]"
      assert_select "[type=submit]", text: "Save Changes"
    end
  end

  test "saving lands back on the Flosis profile" do
    patch workshop_profile_path, params: { user: { name: "Kacper Admi", email_address: @user.email_address } }

    assert_redirected_to workshop_profile_path
    assert_equal "Profile updated.", flash[:notice]
    assert_equal "Kacper Admi", @user.reload.name
  end

  test "a wrong current password is refused on the same screen" do
    patch workshop_profile_path, params: { user: { name: @user.name, email_address: @user.email_address,
                                                   current_password: "wrong", password: "newpass123",
                                                   password_confirmation: "newpass123" } }

    assert_response :unprocessable_entity
    assert_select "[role=alert]", text: /Current password is incorrect/
    assert_select ".m3-card-elevated", count: 0
  end

  test "the AI costs switch is the Workshop switch and saves the moment it is flipped" do
    @user.update!(show_ai_costs: false)
    get workshop_profile_path

    assert_select "[data-ai-costs-card] form[action=?]", workshop_profile_path do
      assert_select "input[type=hidden][name=?][value=?]", "user[show_ai_costs]", "1"
      assert_select "button.clar-toggle[role=switch][aria-checked=false]"
    end
    assert_select "[data-ai-costs-card]", text: /\$0\.68/
    assert_select "[data-ai-costs-card]", text: /€/, count: 0

    patch workshop_profile_path, params: { user: { show_ai_costs: "1" } }
    assert_redirected_to workshop_profile_path
    assert_equal "AI costs are shown on your screens.", flash[:notice]
    assert @user.reload.show_ai_costs?

    get workshop_profile_path
    assert_select "[data-ai-costs-card] button.clar-toggle[role=switch][aria-checked=true]"
    assert_select "[data-ai-costs-card] input[type=hidden][name=?][value=?]", "user[show_ai_costs]", "0"
  end

  test "with costs off for the organization the switch is off, unusable and says so" do
    @workspace.update!(ai_costs_enabled: false)
    @user.update!(show_ai_costs: true)
    get workshop_profile_path

    assert_select "[data-ai-costs-card] button.clar-toggle[role=switch][aria-checked=false][disabled]"
    assert_select "[data-ai-costs-card]", text: /UNAVAILABLE/
    assert_select "[data-ai-costs-card]", text: /Costs are off for the whole organization/
  end

  test "Your access lists the projects with their permissions" do
    get workshop_profile_path

    assert_select "[data-access-card] [data-access-project]"
    assert_select "[data-access-card]", text: /Automations/
  end

  test "the Flosis account menu and Configuration › AI open this page" do
    get workshop_pipeline_path
    assert_select "[data-clar-dropdown-target=panel] a[href=?]", workshop_profile_path, text: /Profile settings/

    get workshop_configuration_path(tab: "ai")
    assert_select "a[href=?]", workshop_profile_path, text: "Profile settings"
  end
end
