class AddAiEstimatePointsToDeliveredIssues < ActiveRecord::Migration[8.1]
  def change
    # AI complexity estimate (halved 1–50 score) synced from the Jira
    # "AI estimation" field — Reporting sums THIS, separate from story_points.
    add_column :delivered_issues, :ai_estimate_points, :decimal, precision: 5, scale: 1
  end
end
