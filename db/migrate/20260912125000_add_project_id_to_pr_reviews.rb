# A PR review belongs to the project whose repository the pull request is in.
# The workspace column stays: it is what the Process page still groups by, and
# Task 13 is explicit that pr_reviews does not move off the workspace.
#
# Guarded per statement: MySQL commits DDL outside the migration transaction, so
# a failure part-way must leave a re-runnable state.
class AddProjectIdToPrReviews < ActiveRecord::Migration[8.1]
  def up
    unless column_exists?(:pr_reviews, :project_id)
      add_column :pr_reviews, :project_id, :bigint
      add_index :pr_reviews, :project_id
    end

    PrReview.reset_column_information

    # Every existing row was written by the one workspace-wide reviewer, so it
    # belongs to whichever project now carries that workspace's repository.
    PrReview.where(project_id: nil).find_each do |review|
      owner = Project.where(workspace_id: review.workspace_id)
                     .where(pr_review_enabled: true).order(:id).first ||
              Project.where(workspace_id: review.workspace_id).order(:id).first
      review.update_columns(project_id: owner.id) if owner
    end

    # The old uniqueness was the bug: swap it for the project-scoped one, and
    # keep a plain index on the workspace for the Process page's grouping.
    if index_exists?(:pr_reviews, [ :workspace_id, :pr_number ], unique: true)
      remove_index :pr_reviews, column: [ :workspace_id, :pr_number ]
    end
    unless index_exists?(:pr_reviews, [ :project_id, :pr_number ], unique: true)
      add_index :pr_reviews, [ :project_id, :pr_number ], unique: true
    end
  end

  # Restoring the workspace-wide uniqueness raises once two projects in one
  # workspace have reviewed the same PR number — which is the ordinary case this
  # migration exists to allow. Rolling back then needs a human decision about
  # which review history to drop; it is not something to do silently here.
  def down
    if index_exists?(:pr_reviews, [ :project_id, :pr_number ], unique: true)
      remove_index :pr_reviews, column: [ :project_id, :pr_number ]
    end
    unless index_exists?(:pr_reviews, [ :workspace_id, :pr_number ], unique: true)
      add_index :pr_reviews, [ :workspace_id, :pr_number ], unique: true
    end
    remove_column :pr_reviews, :project_id if column_exists?(:pr_reviews, :project_id)
  end
end
