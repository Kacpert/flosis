class CreateJiraComments < ActiveRecord::Migration[8.1]
  def change
    create_table :jira_comments do |t|
      t.references :task, null: false, foreign_key: true
      t.string :jira_comment_id
      t.string :author_name
      t.string :author_email
      t.text :body
      t.text :body_adf, limit: 16.megabytes - 1
      t.datetime :jira_created_at
      t.datetime :jira_updated_at

      t.timestamps
    end

    add_index :jira_comments, [:task_id, :jira_comment_id], unique: true
  end
end
