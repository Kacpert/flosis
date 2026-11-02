require "test_helper"
require Rails.root.join("db/migrate/20260912125000_add_project_id_to_pr_reviews")

# Rolling back re-keys the uniqueness from the project to the workspace, which
# two projects reviewing the same PR number make impossible. It has to say so
# before it drops the index the table is relying on.
class AddProjectIdToPrReviewsTest < ActiveSupport::TestCase
  test "down refuses, and keeps the index, when two projects share a PR number" do
    [ projects(:jira_project), projects(:other_jira_project) ].each do |project|
      PrReview.create!(project_id: project.id, workspace_id: project.workspace_id, pr_number: 7)
    end

    error = assert_raises(ActiveRecord::IrreversibleMigration) do
      AddProjectIdToPrReviews.new.down
    end
    assert_match(/7/, error.message)

    connection = ActiveRecord::Base.connection
    assert connection.index_exists?(:pr_reviews, [ :project_id, :pr_number ], unique: true),
           "down dropped the project-scoped uniqueness before discovering it could not restore the other"
  end
end
