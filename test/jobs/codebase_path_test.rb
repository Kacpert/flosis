require "test_helper"

# Five jobs used to chdir into one machine-wide checkout. Each of them is
# handed a project, and each project resolves its own directory — so a second
# client's code is never read out of the first client's tree.
class CodebasePathTest < ActiveSupport::TestCase
  JOBS = [ PrReviewJob, AlertRuleRunJob, BugAttributionJob, AutoEstimateJob,
           BackfillDeliveredEstimatesJob ].freeze

  test "no job carries its own machine-wide codebase constant any more" do
    JOBS.each do |job|
      assert_not job.const_defined?(:CODEBASE_PATH, false),
                 "#{job} still defines CODEBASE_PATH"
    end
  end

  test "a project resolves its own checkout" do
    project = projects(:jira_project)
    project.update_columns(workspace_dir: "/tmp/clients/9/9", github_repo: "acme/partner-portal")

    assert_equal "/tmp/clients/9/9/partner-portal", project.repo_checkout_path
  end
end
