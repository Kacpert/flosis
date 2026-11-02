class AddEstimationFields < ActiveRecord::Migration[8.1]
  def change
    add_column :tasks, :ai_estimate_points, :decimal, precision: 5, scale: 1
    add_column :tasks, :ai_estimated_at, :datetime

    add_column :workspaces, :estimation_trigger, :string, null: false, default: "manual" # sprint|status|briefed|manual
    add_column :workspaces, :estimation_field_names, :json # default ["AI estimation"] set in the MODEL (MySQL: no JSON defaults)
    add_column :workspaces, :estimation_status_trigger, :string, default: "Ready for dev"
    add_column :workspaces, :jira_story_points_field_id, :string
    add_column :workspaces, :jira_ai_estimation_field_id, :string

    create_table :delivered_issues do |t|
      t.references :project, null: false, foreign_key: true
      t.string  :jira_key, null: false
      t.string  :title
      t.string  :issue_type
      t.string  :assignee_email
      t.string  :assignee_name
      t.string  :reporter_email
      t.string  :reporter_name
      t.decimal :story_points, precision: 5, scale: 1
      t.datetime :jira_created_at
      t.datetime :resolved_at
      t.timestamps
      t.index [:project_id, :jira_key], unique: true
      t.index [:project_id, :resolved_at]
    end
  end
end
