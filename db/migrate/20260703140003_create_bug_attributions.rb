class CreateBugAttributions < ActiveRecord::Migration[8.1]
  def change
    create_table :bug_attributions do |t|
      t.references :project, null: false, foreign_key: true
      t.string :jira_key, null: false        # attribution keyed by issue, survives the bug moving
      t.references :task, null: true, foreign_key: true   # from tasks (open) while it exists
      t.string :origin_kind   # new_functionality|existing_code
      t.string :author_name
      t.string :author_email
      t.string :confidence    # high|medium|low
      t.text   :reasoning
      t.string :status, null: false, default: "pending" # pending|done|failed
      t.datetime :analyzed_at
      t.timestamps
      t.index [:project_id, :jira_key], unique: true
    end
  end
end
