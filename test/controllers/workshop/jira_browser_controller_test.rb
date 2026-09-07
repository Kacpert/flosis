require "test_helper"

class Workshop::JiraBrowserControllerTest < ActionDispatch::IntegrationTest
  setup do
    workspaces(:one).update!(workshop_enabled: true)
    sign_in_as(users(:one)) # admin/owner
    post switch_product_path, params: { product: "workshop" }
    @task = tasks(:jira_task) # ELV-1, jira_synced, project jira_project, jira_status_name "In Progress"
  end

  test "renders board tabs for every synced board plus a synthetic Backlog tab" do
    get workshop_jira_browser_path

    assert_response :success
    assert_select ".clar-tab", /Design/
    assert_select ".clar-tab", /DEV board/
    assert_select ".clar-tab", /Backlog/
  end

  test "kanban board shows the task in its mapped column" do
    get workshop_jira_browser_path

    assert_response :success
    # ELV-1 is jira_status_name "In Progress", which maps to the design
    # board's "IN PROGRESS (DESIGN)" column via jira_board_column_statuses.
    assert_select ".clar-key-faint", "ELV-1"
  end

  test "backlog tab renders a table of tasks with no sprint" do
    @task.update!(sprint_id: nil)

    get workshop_jira_browser_path(board: "backlog")

    assert_response :success
    assert_select "table"
    assert_select ".clar-key", "ELV-1"
  end

  test "backlog table is empty when no tasks lack a sprint" do
    get workshop_jira_browser_path(board: "backlog")

    assert_response :success
    assert_select "table"
    assert_select "body", /No tickets match\./
  end

  # A ticket dropped into the NEXT sprint is still backlog: nobody has started
  # it. Jira lists it in the backlog view, and so must we — before this, moving
  # a ticket into an upcoming sprint made it vanish from here entirely.
  test "backlog includes tasks parked in a sprint that has not started" do
    @task.update!(sprint_id: jira_sprints(:future_sprint).jira_sprint_id,
                  sprint_name: jira_sprints(:future_sprint).name)

    get workshop_jira_browser_path(board: "backlog")

    assert_response :success
    assert_select ".clar-key", "ELV-1"
  end

  test "backlog still excludes tasks in a running sprint" do
    @task.update!(sprint_id: jira_sprints(:design_sprint).jira_sprint_id,
                  sprint_name: jira_sprints(:design_sprint).name)

    get workshop_jira_browser_path(board: "backlog")

    assert_response :success
    assert_select "body", /No tickets match\./
  end

  test "tasks already in the pipeline are excluded from the browser" do
    @task.enter_pipeline!(author: users(:one), stage: "briefing")

    get workshop_jira_browser_path

    assert_response :success
    assert_select ".clar-key-faint", count: 0
  end

  test "POST import pulls an existing Jira task into the pipeline and redirects" do
    assert_no_difference -> { Task.count } do
      post workshop_ideas_path, params: { task_id: @task.id }
    end

    @task.reload
    assert @task.in_pipeline?
    assert_equal "briefing", @task.workshop_stage
    assert_equal users(:one), @task.pipeline_author

    assert_redirected_to workshop_idea_path(@task)
    # The toast now names the stage the ticket landed on (START AT picker).
    assert_equal "Imported ELV-1 · Briefing", flash[:clar_toast]
  end

  # Importing a ticket that is already in the pipeline is a stale board, a double
  # click or a back button — not an error. It used to raise on the duplicate v0
  # brief ([task_id, version] is unique) and hand the user a 500 page.
  test "importing a ticket that is already in the pipeline opens it instead of erroring" do
    @task.enter_pipeline!(author: users(:one), stage: "details")
    @task.briefs.create!(workspace: @task.project.workspace, version: 0, origin: "jira",
                         status: "draft", content: "Already here.").make_current!

    assert_no_difference -> { Brief.count } do
      post workshop_ideas_path, params: { task_id: @task.id }
    end

    assert_redirected_to workshop_idea_path(@task, stage: "details")
    assert_match(/already in the pipeline/, flash[:clar_toast])
    assert_equal "details", @task.reload.workshop_stage, "its stage is left alone"
    assert_equal "Already here.", @task.briefs.find_by(version: 0).content, "and so are its documents"
  end

  # A ticket can leave the pipeline and keep its documents, so the seed has to
  # cope with a v0 that already exists.
  test "re-importing a ticket that kept an old v0 brief does not raise" do
    @task.briefs.create!(workspace: @task.project.workspace, version: 0, origin: "jira",
                         status: "draft", content: "From an earlier run.").make_current!

    assert_no_difference -> { Brief.count } do
      post workshop_ideas_path, params: { task_id: @task.id }
    end

    assert_redirected_to workshop_idea_path(@task)
    assert @task.reload.in_pipeline?
  end

  test "POST import seeds a current v0 brief from the task description" do
    post workshop_ideas_path, params: { task_id: @task.id }

    @task.reload
    brief = @task.briefs.find_by(version: 0)
    assert_not_nil brief
    assert brief.current?
    # Origin "jira", not "user" — nobody here wrote it, the ticket did, and the
    # panel labels it accordingly.
    assert_equal "jira", brief.origin
    assert_equal "Jira description", brief.label
    assert_equal "draft", brief.status
    assert_equal @task.description, brief.content
  end

  # The v0 seed used to be the flattened text, so a ticket written with
  # headings, bold and a table arrived as an unreadable wall — cells run
  # together ("FilterWhat it doesExample").
  test "import seeds v0 from the ticket's ADF, keeping headings, bold and tables" do
    @task.update!(description: "Why we're doing thisFilterWhat it does", description_adf: {
      type: "doc", version: 1, content: [
        { type: "heading", attrs: { level: 2 }, content: [ { type: "text", text: "Why we're doing this" } ] },
        { type: "paragraph", content: [
          { type: "text", text: "Customers want " },
          { type: "text", text: "different job lists", marks: [ { type: "strong" } ] }
        ] },
        { type: "table", content: [
          { type: "tableRow", content: [
            { type: "tableHeader", content: [ { type: "paragraph", content: [ { type: "text", text: "Filter" } ] } ] },
            { type: "tableHeader", content: [ { type: "paragraph", content: [ { type: "text", text: "What it does" } ] } ] }
          ] },
          { type: "tableRow", content: [
            { type: "tableCell", content: [ { type: "paragraph", content: [ { type: "text", text: "Tags" } ] } ] },
            { type: "tableCell", content: [ { type: "paragraph", content: [ { type: "text", text: "Matches any tag" } ] } ] }
          ] }
        ] }
      ]
    }.to_json)

    post workshop_ideas_path, params: { task_id: @task.id }

    content = @task.reload.briefs.find_by(version: 0).content
    assert_includes content, "## Why we're doing this"
    assert_includes content, "**different job lists**"
    assert_includes content, "| Filter | What it does |"
    assert_includes content, "| Tags | Matches any tag |"
  end

  test "import falls back to the plain description when the ticket has no ADF" do
    @task.update!(description: "Just plain text", description_adf: nil)

    post workshop_ideas_path, params: { task_id: @task.id }

    assert_equal "Just plain text", @task.reload.briefs.find_by(version: 0).content
  end
end
