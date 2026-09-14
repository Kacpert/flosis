require "test_helper"
require Rails.root.join("db/migrate/20260912123000_backfill_project_configuration")

class BackfillProjectConfigurationTest < ActiveSupport::TestCase
  test "every project inherits the workspace settings it has not set itself" do
    workspaces(:one).update!(pr_review_enabled: true, pr_poll_minutes: 11,
                             github_repo: "acme/widgets", github_token: "wt")
    projects(:jira_project).update!(github_repo: "acme/own")

    BackfillProjectConfiguration.new.up

    inherited = projects(:plain_project).reload
    assert inherited.pr_review_enabled
    assert_equal 11, inherited.pr_poll_minutes
    assert_equal "acme/widgets", inherited.github_repo

    assert_equal "acme/own", projects(:jira_project).reload.github_repo,
                 "a project that set its own repo keeps it"
  end
end
