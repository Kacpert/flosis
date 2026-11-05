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

  test "Create Tasks shows a Setup link to Configuration for admins" do
    get workshop_pipeline_path

    assert_response :success
    assert_select "a[href=?]", workshop_configuration_path(tab: "briefing"), text: /\A\s*Setup\s*\z/
  end

  test "New idea offers START AT while the project has Briefing on" do
    get workshop_pipeline_path

    assert_select "[data-clar-start-stage-target='card'][data-stage='briefing']"
  end

  test "with Briefing off, New idea offers no START AT choice and starts in Details" do
    @task.project.update!(briefing_enabled: false)

    get workshop_pipeline_path

    assert_select "[data-clar-start-stage-target='card']", count: 0
    assert_select "input[name='idea[start_stage]'][value='details']"
  end

  test "with Briefing off and nothing left in it, the Briefing filter chip is gone" do
    @task.project.update!(briefing_enabled: false)
    @task.update!(workshop_stage: "details")

    get workshop_pipeline_path

    assert_select ".clar-chip", text: /Briefing/, count: 0
    assert_select ".clar-chip", text: /Details/
  end

  test "with Briefing off, the Briefing filter chip stays while tasks still sit in it" do
    @task.project.update!(briefing_enabled: false)

    get workshop_pipeline_path

    assert_select ".clar-chip", text: /Briefing/
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
