require "test_helper"
require Rails.root.join("db/migrate/20260912123500_narrow_project_configuration_fanout")

# The settings that cost money or make outbound calls belong to the one project
# the integration was really about. Everything else keeps what it inherited.
class NarrowProjectConfigurationFanoutTest < ActiveSupport::TestCase
  setup do
    @workspace = workspaces(:one)
    @workspace.update!(github_repo: "acme/app", pr_review_enabled: true, figma_read_enabled: true)
    # The fixtures give workspace one two Jira projects, which is the ambiguous
    # case the migration refuses to touch. Drop the second one's external_type
    # so there is a single primary to designate.
    projects(:other_jira_project).update_columns(external_type: nil)
    @primary = projects(:jira_project)
    @other = projects(:plain_project)

    [ @primary, @other ].each do |project|
      project.update_columns(github_repo: "acme/app", pr_review_enabled: true, figma_read_enabled: true)
    end
  end

  test "the Jira project keeps the repo and the polling" do
    NarrowProjectConfigurationFanout.new.up

    @primary.reload
    assert_equal "acme/app", @primary.github_repo
    assert @primary.pr_review_enabled
    assert @primary.figma_read_enabled
  end

  test "every other project loses the copied repo and stops polling" do
    NarrowProjectConfigurationFanout.new.up

    @other.reload
    assert_nil @other.github_repo
    assert_not @other.pr_review_enabled
    assert_not @other.figma_read_enabled
  end

  test "a value the project set for itself is left alone" do
    @other.update_columns(github_repo: "acme/its-own")

    NarrowProjectConfigurationFanout.new.up

    assert_equal "acme/its-own", @other.reload.github_repo
  end

  test "with no single Jira project nothing is designated and nothing is cleared" do
    @primary.update_columns(external_type: nil)

    NarrowProjectConfigurationFanout.new.up

    assert_equal "acme/app", @other.reload.github_repo
    assert_equal "acme/app", @primary.reload.github_repo
  end
end
