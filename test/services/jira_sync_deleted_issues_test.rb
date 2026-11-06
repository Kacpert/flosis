require "test_helper"

# JiraSyncService#sync_deleted_issues: a task whose issue Jira confirms is gone
# is soft-removed (or, in Create Tasks, becomes a local idea); anything Jira
# did not clearly answer leaves every task alone.
class JiraSyncDeletedIssuesTest < ActiveSupport::TestCase
  setup do
    @project = projects(:jira_project) # key ELV
    @task = tasks(:jira_task)          # ELV-1
  end

  # Nothing open in Jira, so only the deletion pass does anything; its
  # answers are set per test.
  def client(keys:, browse: true, gone: [])
    Class.new do
      define_method(:fetch_boards) { |_key| [] }
      define_method(:fetch_statuses) { {} }
      define_method(:fetch_sprint_issue_keys) { |_id| [] }
      define_method(:fetch_all_comments) { |_key| [] }
      define_method(:resolve_story_points_field) { nil }
      define_method(:fetch_field_id) { |_name| nil }
      define_method(:fetch_issues) { |_key, story_points_field_id: nil| [] }
      define_method(:fetch_recent_done_issues) { |_key, **| [] }
      define_method(:fetch_issue_keys) { |_key| keys }
      define_method(:can_browse_project?) { |_key| browse }
      define_method(:issue_gone?) { |key, project_key| project_key == "ELV" && gone.include?(key) }
    end.new
  end

  def sync(c)
    JiraSyncService.new(@project, client: c).sync
  end

  test "a task whose issue was deleted in Jira is soft-removed" do
    sync client(keys: [], gone: [ "ELV-1" ])

    assert @task.reload.deleted_at.present?
    assert_equal "ELV-1", @task.external_reference
  end

  test "a task in Create Tasks becomes a local idea instead" do
    @task.update!(in_pipeline: true, workshop_stage: "details")

    sync client(keys: [], gone: [ "ELV-1" ])

    @task.reload
    assert_nil @task.deleted_at
    assert_nil @task.external_reference
    assert @task.in_pipeline?
  end

  test "a task Jira still lists is left alone, whatever a single lookup says" do
    sync client(keys: [ "ELV-1" ], gone: [ "ELV-1" ])

    assert_nil @task.reload.deleted_at
  end

  test "a missing key Jira does not confirm as gone is left alone" do
    sync client(keys: [], gone: [])

    assert_nil @task.reload.deleted_at
  end

  test "nothing is removed when the key list cannot be fetched" do
    sync client(keys: nil, gone: [ "ELV-1" ])

    assert_nil @task.reload.deleted_at
  end

  test "nothing is removed when the login can no longer browse the project" do
    sync client(keys: [], browse: false, gone: [ "ELV-1" ])

    assert_nil @task.reload.deleted_at
  end

  test "a soft-removed task comes back when its issue is in Jira again" do
    @task.update!(deleted_at: 2.days.ago)

    sync client(keys: [ "ELV-1" ])

    assert_nil @task.reload.deleted_at
  end

  test "local tasks and other projects' tasks are never touched" do
    sync client(keys: [], gone: [ "ELV-1", "SEC-1" ])

    assert_nil tasks(:local_task).reload.deleted_at
    assert_nil tasks(:secret_task).reload.deleted_at
    assert_equal "SEC-1", tasks(:secret_task).external_reference
  end

  test "one task that cannot be removed does not stop the others, nor the rest of the sync" do
    other = @project.tasks.create!(name: "ELV-77 Another", external_type: "jira", external_reference: "ELV-77", sprint_id: 5, sprint_name: "S")
    original = Task.instance_method(:remove_deleted_jira_issue!)
    Task.define_method(:remove_deleted_jira_issue!) do
      raise ActiveRecord::RecordInvalid, self if external_reference == "ELV-1"
      original.bind_call(self)
    end
    begin
      sync client(keys: [], gone: [ "ELV-1", "ELV-77" ])
    ensure
      Task.define_method(:remove_deleted_jira_issue!, original)
    end

    assert_nil @task.reload.deleted_at
    assert other.reload.deleted_at.present?
  end
end
