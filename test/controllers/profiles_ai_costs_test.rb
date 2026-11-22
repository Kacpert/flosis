require "test_helper"

# SCRUM-70: AI costs are each person's to turn on, while the organization
# allows them.
class ProfilesAiCostsTest < ActionDispatch::IntegrationTest
  setup { sign_in_as(users(:one)) }

  test "a person turns AI costs on" do
    patch profile_path, params: { user: { show_ai_costs: "1" } }
    assert_redirected_to profile_path
    assert users(:one).reload.show_ai_costs?

    patch profile_path, params: { user: { show_ai_costs: "0" } }
    refute users(:one).reload.show_ai_costs?
  end

  test "the profile offers the AI costs switch while the organization shows costs" do
    get profile_path
    assert_select "input[type=checkbox][name='user[show_ai_costs]']:not([disabled])"
    assert_includes response.body, "($0.94 this month)"
  end

  test "the profile card says Unavailable while the organization hides costs" do
    workspaces(:one).update!(ai_costs_enabled: false)
    get profile_path
    assert_includes response.body, "UNAVAILABLE"
    assert_includes response.body, "Costs are off for the whole organization."
    assert_select "input[type=checkbox][name='user[show_ai_costs]'][disabled]"
  end
end
