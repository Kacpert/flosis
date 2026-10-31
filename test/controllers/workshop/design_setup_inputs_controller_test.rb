require "test_helper"

class Workshop::DesignSetupInputsControllerTest < ActionDispatch::IntegrationTest
  setup do
    workspaces(:one).update!(workshop_enabled: true)
    @project = projects(:jira_project)
    sign_in_as(users(:one))
    post switch_product_path, params: { product: "workshop" }
    post switch_workshop_project_path, params: { project_id: @project.id }
  end

  def add_role(password: "s3cret-pass", login_url: "https://app.test/login")
    post add_role_workshop_design_setup_inputs_path,
         params: { role: { name: "Admin", login_url: login_url, username: "a", password: password } }
  end

  # Ruling (Plan 5 Task 2): assert_select "body", text:, count: 0 passes with
  # the text on the page, so absence is checked on the body itself.
  test "a workspace admin who isn't staff neither sees nor changes setup inputs" do
    get workshop_configuration_path(tab: "designs")
    assert_no_match(/ROLES/, response.body)
    add_role
    assert_response :not_found
    assert_equal 0, @project.design_setup_roles.count
    patch workshop_design_setup_inputs_path, params: { project: { design_app_url: "https://app.test" } }
    assert_response :not_found
    assert_nil @project.reload.design_app_url
  end

  test "staff add a role whose password is stored encrypted and never shown" do
    users(:one).update!(flosis_staff: true)
    add_role
    role = @project.design_setup_roles.sole
    assert_equal "s3cret-pass", role.password
    assert_not_equal "s3cret-pass", DesignSetupRole.connection.select_value("SELECT password FROM design_setup_roles WHERE id = #{role.id}")
    get workshop_configuration_path(tab: "designs")
    assert_match(/ROLES/, response.body)
    assert_includes response.body, "https://app.test/login"
    assert_not_includes response.body, "s3cret-pass"
  end

  test "staff set the app URL and Figma files" do
    users(:one).update!(flosis_staff: true)
    patch workshop_design_setup_inputs_path, params: { project: { design_app_url: "https://app.test", design_figma_urls: "https://figma.com/a\nhttps://figma.com/b" } }
    assert_equal %w[https://figma.com/a https://figma.com/b], @project.reload.design_figma_urls
    assert_equal "https://app.test", @project.design_app_url
  end

  test "a blank password keeps the stored one, and a role can be removed" do
    users(:one).update!(flosis_staff: true)
    add_role
    role = @project.design_setup_roles.sole
    patch update_role_workshop_design_setup_inputs_path,
          params: { id: role.id, role: { name: "Owner", login_url: "https://app.test/login", username: "o", password: "" } }
    assert_equal [ "Owner", "o", "s3cret-pass" ], role.reload.values_at(:name, :username, :password)
    delete remove_role_workshop_design_setup_inputs_path, params: { id: role.id }
    assert_equal 0, @project.design_setup_roles.count
  end

  test "a login URL that isn't http(s) is refused" do
    users(:one).update!(flosis_staff: true)
    add_role(login_url: "javascript:alert(1)")
    assert_equal 0, @project.design_setup_roles.count
    assert_match(/Login url/i, flash[:alert].to_s)
  end

  test "staff upload materials and remove them" do
    users(:one).update!(flosis_staff: true)
    file = Rack::Test::UploadedFile.new(StringIO.new("brand book"), "application/pdf", original_filename: "brand.pdf")
    patch workshop_design_setup_inputs_path, params: { project: { design_materials: [ file ] } }
    material = @project.reload.design_materials.sole
    assert_equal "brand.pdf", material.filename.to_s
    get workshop_configuration_path(tab: "designs")
    assert_includes response.body, "brand.pdf"
    delete remove_material_workshop_design_setup_inputs_path, params: { attachment_id: material.id }
    assert_empty @project.reload.design_materials
  end
end
