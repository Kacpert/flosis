require "test_helper"

# Profile settings (where the AI costs switch lives, SCRUM-70) must be reachable
# from the Flosis account menu, also for a person without Time & HR.
class FlosisAccountMenuProfileTest < ActionDispatch::IntegrationTest
  setup { workspaces(:one).update!(workshop_enabled: true) }

  test "the Flosis account menu links to Profile settings" do
    sign_in_as(users(:one))
    post switch_product_path, params: { product: "workshop" }
    get workshop_pipeline_path
    assert_response :success

    assert_select "[data-clar-dropdown-target=panel] a[href=?]", profile_path, text: /Profile settings/
  end

  test "a person with Flosis only opens Profile settings from that link" do
    sign_in_as(users(:client_user))
    get profile_path
    assert_response :success
    assert_select "[data-ai-costs-card]"
  end
end
