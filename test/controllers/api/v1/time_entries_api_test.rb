require "test_helper"

class Api::V1::TimeEntriesApiTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:two)                      # employee, member of jira_project only
    @workspace = workspaces(:one)
    @project = projects(:jira_project)
    @foreign = projects(:other_jira_project) # no membership for @user
    _, @raw = ApiToken.issue!(user: @user, workspace: @workspace, name: "test")
  end

  def auth(raw = @raw)
    { "Authorization" => "Bearer #{raw}" }
  end

  def book(params, raw = @raw)
    post api_v1_time_entries_path, params: params.to_json,
         headers: auth(raw).merge("Content-Type" => "application/json")
  end

  test "books a completed entry from started_at and duration_minutes" do
    assert_difference -> { @user.time_entries.count }, 1 do
      book(project_id: @project.id, description: "Code review", started_at: "2026-11-03T09:00:00+01:00", duration_minutes: 90)
    end
    assert_response :created
    body = response.parsed_body["time_entry"]
    assert_equal 90, body["duration_minutes"]
    entry = @user.time_entries.find(body["id"])
    assert_equal @workspace, entry.workspace
    assert_equal Time.zone.parse("2026-11-03T10:30:00+01:00"), entry.stopped_at
    assert_equal 5400, entry.duration_seconds
    assert_equal "Code review", entry.description
  end

  test "books from started_at and stopped_at, a time without offset read as Warsaw" do
    book(project_id: @project.id, started_at: "2026-11-03 09:00", stopped_at: "2026-11-03 17:15")
    assert_response :created
    entry = @user.time_entries.find(response.parsed_body.dig("time_entry", "id"))
    assert_equal Time.find_zone("Warsaw").local(2026, 11, 3, 9, 0), entry.started_at
    assert_equal 8 * 3600 + 15 * 60, entry.duration_seconds
  end

  test "links a task by its Jira key" do
    book(project_id: @project.id, started_at: "2026-11-03T09:00", duration_minutes: 30, task_key: "elv-1")
    assert_response :created
    assert_equal tasks(:jira_task), TimeEntry.last.task

    book(project_id: @project.id, started_at: "2026-11-03T09:00", duration_minutes: 30, task_key: "ELV-999")
    assert_response :unprocessable_entity
  end

  test "refuses a project the person is not on" do
    assert_no_difference -> { TimeEntry.count } do
      book(project_id: @foreign.id, started_at: "2026-11-03T09:00", duration_minutes: 60)
    end
    assert_response :unprocessable_entity
  end

  test "refuses entries with no end, a backwards end, or over 24 hours" do
    assert_no_difference -> { TimeEntry.count } do
      book(project_id: @project.id, started_at: "2026-11-03T09:00")
      assert_response :unprocessable_entity
      book(project_id: @project.id, started_at: "2026-11-03T09:00", stopped_at: "2026-11-03T08:00")
      assert_response :unprocessable_entity
      book(project_id: @project.id, started_at: "2026-11-03T09:00", duration_minutes: 0)
      assert_response :unprocessable_entity
      book(project_id: @project.id, started_at: "2026-11-03T09:00", duration_minutes: 1500)
      assert_response :unprocessable_entity
      book(project_id: @project.id, started_at: "yesterday", duration_minutes: 60)
      assert_response :unprocessable_entity
    end
  end

  test "rejects a missing, wrong or revoked token" do
    post api_v1_time_entries_path, params: { project_id: @project.id }.to_json, headers: { "Content-Type" => "application/json" }
    assert_response :unauthorized

    book({ project_id: @project.id, started_at: "2026-11-03T09:00", duration_minutes: 60 }, "gold_pat_nope")
    assert_response :unauthorized

    ApiToken.authenticate(@raw).revoke!
    book(project_id: @project.id, started_at: "2026-11-03T09:00", duration_minutes: 60)
    assert_response :unauthorized
  end

  test "a token without the scope cannot book, and losing HR access loses the token" do
    _, read_only = ApiToken.issue!(user: @user, workspace: @workspace, name: "ro", scopes: %w[projects:read])
    book({ project_id: @project.id, started_at: "2026-11-03T09:00", duration_minutes: 60 }, read_only)
    assert_response :forbidden

    workspace_memberships(:two_employee).update!(time_hr_access: false)
    book(project_id: @project.id, started_at: "2026-11-03T09:00", duration_minutes: 60)
    assert_response :forbidden
  end

  test "lists only the projects the person can book" do
    get api_v1_projects_path, headers: auth
    assert_response :ok
    names = response.parsed_body["projects"].map { |project| project["name"] }
    assert_includes names, @project.name
    assert_not_includes names, @foreign.name
    assert_equal "ELV", response.parsed_body["projects"].find { |p| p["id"] == @project.id }["jira_key"]
  end

  test "the stored token is only a digest" do
    token = ApiToken.authenticate(@raw)
    assert token
    assert_not_equal @raw, token.token_digest
    assert_equal @raw.last(4), token.token_hint
    assert @raw.start_with?("gold_pat_")
  end
end

class Api::V1::TimeEntriesDeleteApiTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:two)
    @workspace = workspaces(:one)
    @project = projects(:jira_project)
    _, @raw = ApiToken.issue!(user: @user, workspace: @workspace, name: "test")
  end

  def entry_for(user, started_at)
    TimeEntry.create!(workspace: @workspace, user: user, project: @project,
                      started_at: started_at, stopped_at: started_at + 1.hour)
  end

  def delete_entry(entry, raw = @raw)
    delete api_v1_time_entry_path(entry), headers: { "Authorization" => "Bearer #{raw}" }
  end

  test "deletes one of the person's entries from the last 36 days" do
    entry = entry_for(@user, 35.days.ago)
    delete_entry(entry)
    assert_response :ok
    assert_equal entry.id, response.parsed_body.dig("deleted", "id")
    assert_not TimeEntry.exists?(entry.id)
  end

  test "refuses an entry that started more than 36 days ago" do
    entry = entry_for(@user, 37.days.ago)
    delete_entry(entry)
    assert_response :unprocessable_entity
    assert TimeEntry.exists?(entry.id)
  end

  test "someone else's entry is not found" do
    entry = entry_for(users(:one), 1.day.ago)
    delete_entry(entry)
    assert_response :not_found
    assert TimeEntry.exists?(entry.id)
  end

  test "a token without the delete scope cannot delete" do
    _, create_only = ApiToken.issue!(user: @user, workspace: @workspace, name: "c", scopes: %w[time_entries:create projects:read])
    entry = entry_for(@user, 1.day.ago)
    delete_entry(entry, create_only)
    assert_response :forbidden
    assert TimeEntry.exists?(entry.id)
  end
end
