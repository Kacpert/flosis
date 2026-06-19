require "test_helper"
require "webmock/minitest"

class JiraUpdatedAtSyncTest < ActiveSupport::TestCase
  test "parse_issue extracts the Jira updated timestamp" do
    client = JiraClient.allocate
    client.instance_variable_set(:@domain, "ex.atlassian.net")
    issue = {
      "key" => "DEV-1", "fields" => {
        "summary" => "x", "status" => { "name" => "To Do", "statusCategory" => { "key" => "new" } },
        "updated" => "2026-06-10T12:00:00.000+0200", "issuetype" => { "name" => "Bug" }
      }
    }
    parsed = client.send(:parse_issue, issue)
    assert_equal "2026-06-10T12:00:00.000+0200", parsed[:updated]
  end
end
