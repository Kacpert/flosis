# Designs in the Workshop pipeline.
#
# tasks.designs_described_sha is the working branch's commit the Details
# description was last written from (Designs::DescribeJob): the Designs screen
# says so when the designs have moved on since.
#
# design_approvals.jira_links_synced_at and jira_links_error say how the
# approval's Web links reached the Jira issue: when they last did, and why
# they did not. The error is text, as design_repo_error is: a Jira error can
# run past a string column, and MySQL in strict mode refuses that.
#
# Guarded per statement: MySQL commits DDL outside the migration transaction,
# so a failure part-way must leave a re-runnable state.
class AddDesignsPipelineColumns < ActiveRecord::Migration[8.1]
  def up
    add_column :tasks, :designs_described_sha, :string unless column_exists?(:tasks, :designs_described_sha)
    unless column_exists?(:design_approvals, :jira_links_synced_at)
      add_column :design_approvals, :jira_links_synced_at, :datetime
    end
    add_column :design_approvals, :jira_links_error, :text unless column_exists?(:design_approvals, :jira_links_error)
  end

  def down
    remove_column :design_approvals, :jira_links_error if column_exists?(:design_approvals, :jira_links_error)
    remove_column :design_approvals, :jira_links_synced_at if column_exists?(:design_approvals, :jira_links_synced_at)
    remove_column :tasks, :designs_described_sha if column_exists?(:tasks, :designs_described_sha)
  end
end
