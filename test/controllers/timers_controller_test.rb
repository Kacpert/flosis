require "test_helper"

# The running-timer bar lets you correct when you actually started — you notice
# ten minutes in that you forgot to hit play. update_running is the only way to
# move started_at, so it has to accept the change while refusing values that
# would make the on-screen counter nonsense (a future start counts backwards).
class TimersControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:two) # employee
    @workspace = workspaces(:one)
    @project = projects(:jira_project)
    sign_in_as(@user)
  end

  def start_timer(started_at: 20.minutes.ago)
    @workspace.time_entries.create!(
      user: @user, project: @project, description: "Fixing prices", started_at: started_at
    )
  end

  # --- the timer bar's task field -------------------------------------------
  # There is no task <select> any more: you pick the ticket straight from the
  # description input's typeahead. The old select was worse than redundant — it
  # was shown by default and only hidden once an async fetch came back, so it
  # flashed back into the bar on every Turbo navigation.

  test "the timer bar renders no task select, running or idle" do
    get time_entries_path
    assert_response :success
    assert_select "select[name*=?]", "task_id", count: 0

    start_timer
    get time_entries_path
    assert_response :success
    assert_select "select[name*=?]", "task_id", count: 0
  end

  # The inline edit row on the entries list had the same problem, plus one of
  # its own: the task <select> was as wide as its longest option, so a project
  # with hundreds of Jira tasks tore the row into three ragged lines.
  test "an entry's inline edit row has no task select either" do
    entry = @workspace.time_entries.create!(user: @user, project: @project, description: "Fixing prices",
                                            started_at: 3.hours.ago, stopped_at: 1.hour.ago)

    get time_entries_path

    assert_response :success
    assert_select "form.m3-entry-edit"
    assert_select "form.m3-entry-edit select[name*=?]", "task_id", count: 0
    # The task still travels with the entry, and the typeahead can change it.
    assert_select "form.m3-entry-edit input[type=hidden][name=?]", "time_entry[task_id]"
    assert_select "form.m3-entry-edit input[data-jira-task-search-target=?]", "input"
    assert_not_nil entry.reload
  end

  test "the timer bar keeps the hidden task_id field the typeahead writes into" do
    get time_entries_path

    assert_response :success
    assert_select "input[type=hidden][data-jira-task-search-target=?]", "taskId"
    assert_select "input[data-jira-task-search-target=?]", "input"
  end

  # --- moving the start time ------------------------------------------------

  test "moves the start time to an earlier point today" do
    timer = start_timer(started_at: 20.minutes.ago)
    target = 90.minutes.ago.change(sec: 0)

    patch update_running_timer_path, params: {
      time_entry: { started_at: target.strftime("%Y-%m-%dT%H:%M") }
    }

    assert_in_delta target.to_i, timer.reload.started_at.to_i, 60
  end

  test "keeps the description and project when only the start time moves" do
    timer = start_timer

    patch update_running_timer_path, params: {
      time_entry: { started_at: 45.minutes.ago.strftime("%Y-%m-%dT%H:%M") }
    }

    timer.reload
    assert_equal "Fixing prices", timer.description
    assert_equal @project.id, timer.project_id
  end

  test "refuses a start time in the future" do
    timer = start_timer
    was = timer.started_at

    patch update_running_timer_path, params: {
      time_entry: { started_at: 2.hours.from_now.strftime("%Y-%m-%dT%H:%M") }
    }

    assert_equal was.to_i, timer.reload.started_at.to_i,
      "a future start time would make the counter run backwards"
  end

  test "refuses an unparseable start time rather than blanking it" do
    timer = start_timer
    was = timer.started_at

    patch update_running_timer_path, params: { time_entry: { started_at: "not a time" } }

    assert_equal was.to_i, timer.reload.started_at.to_i
    assert_not_nil timer.started_at
  end

  # --- the stale task_id bug ------------------------------------------------

  # The bar fires auto-save the instant the project select changes, while the
  # task list is still being fetched. Without this, the entry keeps the task it
  # had under the OLD project — a task that belongs to a different project.
  test "changing the project clears a task belonging to the old project" do
    old_task = tasks(:jira_task)
    timer = start_timer
    timer.update!(project: old_task.project, task: old_task)

    other_project = projects(:plain_project)
    patch update_running_timer_path, params: {
      time_entry: { project_id: other_project.id, task_id: old_task.id }
    }

    timer.reload
    assert_equal other_project.id, timer.project_id
    assert_nil timer.task_id, "a task from the previous project must not follow the entry"
  end

  test "keeps the task when it belongs to the project being set" do
    task = tasks(:jira_task)
    timer = start_timer

    patch update_running_timer_path, params: {
      time_entry: { project_id: task.project_id, task_id: task.id }
    }

    timer.reload
    assert_equal task.id, timer.task_id
  end

  # --- description is not lost on a project change --------------------------

  test "the typed description survives a project change" do
    timer = start_timer

    patch update_running_timer_path, params: {
      time_entry: { description: "Typed but not yet blurred", project_id: projects(:plain_project).id }
    }

    assert_equal "Typed but not yet blurred", timer.reload.description
  end
end
