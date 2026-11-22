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

  # SCRUM-70: the Flosis-admin shell — billing first, then staff pages.
  test "the staff sidebar lists billing and staff pages" do
    users(:one).update!(flosis_staff: true)
    sign_in_as(users(:one))
    get hidmin_plans_path

    assert_select "header", text: /FLOSIS ADMIN/
    assert_select "nav[aria-label='Flosis admin']" do
      assert_select "a[href=?]", hidmin_plans_path, text: /Plans/
      assert_select "a[href=?]", hidmin_ai_models_path, text: /Models & prices/
      assert_select "a[href=?]", hidmin_workspaces_path, text: /Organizations/
      assert_select "a[href=?]", hidmin_root_path, text: /Overview/
      assert_select "a[href=?]", hidmin_users_path, text: /People/
    end
  end

  test "every billing write is hidden from non-staff" do
    sign_in_as(users(:one))
    post hidmin_plans_path, params: { ai_plan: { name: "Sneaky", monthly_price_usd: 1, margin_percent: 1 } }
    assert_response :not_found
    patch assign_plan_hidmin_workspace_path(workspaces(:one)), params: { ai_plan_id: ai_plans(:scale).id }
    assert_response :not_found
    post read_hidmin_ai_models_path
    assert_response :not_found
    assert_nil workspaces(:one).reload.ai_plan_id
  end

  private

  def pages
    [ hidmin_root_path, hidmin_workspaces_path, hidmin_workspace_path(workspaces(:one)),
      new_hidmin_workspace_path, hidmin_users_path, hidmin_user_path(users(:two)),
      hidmin_plans_path, new_hidmin_plan_path, edit_hidmin_plan_path(ai_plans(:scale)), hidmin_ai_models_path ]
  end
end
