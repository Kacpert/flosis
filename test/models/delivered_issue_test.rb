require "test_helper"

class DeliveredIssueTest < ActiveSupport::TestCase
  test "valid with project and jira_key" do
    issue = DeliveredIssue.new(project: projects(:jira_project), jira_key: "ELV-1")
    assert issue.valid?
  end

  test "invalid without jira_key" do
    issue = DeliveredIssue.new(project: projects(:jira_project))
    assert_not issue.valid?
    assert issue.errors[:jira_key].present?
  end

  test "invalid without project" do
    issue = DeliveredIssue.new(jira_key: "ELV-1")
    assert_not issue.valid?
  end

  test "unique jira_key per project" do
    DeliveredIssue.create!(project: projects(:jira_project), jira_key: "ELV-900")
    dup = DeliveredIssue.new(project: projects(:jira_project), jira_key: "ELV-900")
    assert_not dup.valid?
  end
end
