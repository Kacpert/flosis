require "test_helper"

class Workshop::ProjectDesignsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @preview_root = Pathname(Dir.mktmpdir("preview"))
    ENV["DESIGNS_PREVIEW_ROOT"] = @preview_root.to_s
    workspaces(:one).update!(workshop_enabled: true)
    @project = projects(:jira_project)
    @idea = tasks(:jira_task)
    @idea.update!(project: @project, external_reference: "REC-1")
    @idea.enter_pipeline!(author: users(:one), stage: "briefing")
    sign_in_as(users(:one))
    post switch_product_path, params: { product: "workshop" }
    post switch_workshop_project_path, params: { project_id: @project.id }
  end

  teardown do
    ENV.delete("DESIGNS_PREVIEW_ROOT")
    FileUtils.remove_entry(@preview_root)
  end

  test "the sidebar links Designs for whoever works on tasks" do
    get workshop_pipeline_path
    assert_select "a[href=?]", workshop_designs_overview_path, text: /Designs/
  end

  test "a project without designs says so, and sends an admin to set them up" do
    get workshop_designs_overview_path
    assert_response :success
    assert_match(/Designs isn.t set up for this project/, response.body)
    assert_select "a[href=?]", workshop_configuration_path(tab: "designs")
    assert_select "iframe", count: 0
  end

  test "a failed setup shows why" do
    @project.update!(designs_enabled: true, design_repo_status: "error", design_repo_error: "git push failed: <denied>")
    get workshop_designs_overview_path
    assert_includes response.body, "git push failed: &lt;denied&gt;"
  end

  test "a project with designs shows its whole design, sandboxed, and the conversations of its tasks" do
    @project.update!(designs_enabled: true, design_repo: "acme/designs", design_repo_token: "dt",
                     design_repo_status: "ready", design_preview_token: "t0k")
    FileUtils.mkdir_p(@preview_root.join("t0k/master"))
    ChatSession.designs_for!(@idea, user: users(:one), codebase_path: @preview_root.to_s)

    get workshop_designs_overview_path
    assert_response :success
    frame = css_select("iframe").sole
    assert_equal "allow-scripts allow-forms allow-popups allow-modals", frame["sandbox"]
    match = %r{/test-workspace/elvium/(#{Designs::PreviewGrant::FORMAT.source})/design/index\.html\z}.match(frame["src"])
    assert match, frame["src"]
    assert_equal [ @project, "master" ], Designs::PreviewGrant.read(match[1])
    assert_select "a[href=?]", Designs::Publisher.new(@project, nil).url("master"), text: /Open/
    assert_select "a[href=?]", workshop_idea_designs_path(@idea), text: /#{@idea.name}/
  end
end
