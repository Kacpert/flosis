require "test_helper"

class BugAttributionTest < ActiveSupport::TestCase
  test "valid with project and jira_key" do
    attribution = BugAttribution.new(project: projects(:jira_project), jira_key: "ELV-1")
    assert attribution.valid?
  end

  test "invalid without jira_key" do
    attribution = BugAttribution.new(project: projects(:jira_project))
    assert_not attribution.valid?
    assert attribution.errors[:jira_key].present?
  end

  test "invalid without project" do
    attribution = BugAttribution.new(jira_key: "ELV-1")
    assert_not attribution.valid?
  end

  test "unique jira_key per project" do
    BugAttribution.create!(project: projects(:jira_project), jira_key: "ELV-900")
    dup = BugAttribution.new(project: projects(:jira_project), jira_key: "ELV-900")
    assert_not dup.valid?
  end

  test "same jira_key is allowed across different projects" do
    BugAttribution.create!(project: projects(:jira_project), jira_key: "DUP-1")
    other = BugAttribution.new(project: projects(:other_jira_project), jira_key: "DUP-1")
    assert other.valid?
  end

  test "defaults status to pending" do
    attribution = BugAttribution.create!(project: projects(:jira_project), jira_key: "ELV-901")
    assert_equal "pending", attribution.status
  end

  test "status must be one of pending done failed" do
    attribution = BugAttribution.new(project: projects(:jira_project), jira_key: "ELV-902", status: "bogus")
    assert_not attribution.valid?
    assert attribution.errors[:status].present?
  end

  test "task is optional" do
    attribution = BugAttribution.new(project: projects(:jira_project), jira_key: "ELV-903", task: nil)
    assert attribution.valid?
  end

  test "task can be set when the bug is still open" do
    task = tasks(:jira_task)
    attribution = BugAttribution.new(project: projects(:jira_project), jira_key: task.external_reference, task: task)
    assert attribution.valid?
  end

  test "origin_kind must be new_functionality or existing_code when present" do
    attribution = BugAttribution.new(project: projects(:jira_project), jira_key: "ELV-904", origin_kind: "bogus")
    assert_not attribution.valid?
    assert attribution.errors[:origin_kind].present?
  end

  test "origin_kind may be blank" do
    attribution = BugAttribution.new(project: projects(:jira_project), jira_key: "ELV-905", origin_kind: nil)
    assert attribution.valid?
  end

  test "confidence must be high medium or low when present" do
    attribution = BugAttribution.new(project: projects(:jira_project), jira_key: "ELV-906", confidence: "super-sure")
    assert_not attribution.valid?
    assert attribution.errors[:confidence].present?
  end

  test "confidence may be blank" do
    attribution = BugAttribution.new(project: projects(:jira_project), jira_key: "ELV-907", confidence: nil)
    assert attribution.valid?
  end
end
