require "test_helper"

class BackfillDeliveredEstimatesJobTest < ActiveJob::TestCase
  include AiRunTestHelper

  # SCRUM-70: the one-off backfill's runs are recorded like any other.
  test "backfill names the backfill automation" do
    project = projects(:jira_project)
    checkout!(project)
    issue = project.delivered_issues.create!(jira_key: "ELV-500", title: "Old export", description: "Exports were slow.")

    with_attributed_ai("SCORE: 40") do |seen|
      BackfillDeliveredEstimatesJob.perform_now(project.id)
      assert_equal "AI estimate backfill", seen.last.automation
      assert_equal issue, seen.last.item
      assert_equal "estimates", seen.last.area
    end
  end
end
