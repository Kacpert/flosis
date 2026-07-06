require "test_helper"

class Workshop::PipelineControllerTest < ActionDispatch::IntegrationTest
  setup do
    workspaces(:one).update!(workshop_enabled: true)
    sign_in_as(users(:one)) # admin/owner
    post switch_product_path, params: { product: "workshop" }
    @task = tasks(:jira_task) # Jira-synced fixture (project projects(:jira_project), key ELV-1)
    @task.update!(in_pipeline: true, workshop_stage: "briefing", pipeline_entered_at: 1.hour.ago)
  end

  test "lists pipeline ideas with stage badge" do
    get workshop_pipeline_path
    assert_response :success
    assert_select "h1", "Create Tasks"
    assert_select ".clar-row", minimum: 1
    assert_select ".clar-badge", /Briefing/
  end

  test "Create Tasks shows a Briefing setup link to Configuration for admins" do
    get workshop_pipeline_path

    assert_response :success
    assert_select "a[href=?]", workshop_configuration_path(tab: "briefing"), text: /Briefing setup/
  end

  test "stage filter narrows the list" do
    get workshop_pipeline_path(stage: "ready")
    assert_select ".clar-row", count: 0
    assert_select "[data-empty]", /No tickets match/
  end

  test "search matches key and title" do
    get workshop_pipeline_path(q: @task.external_reference.to_s)
    assert_select ".clar-row", minimum: 1
  end
end
