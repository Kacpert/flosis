class CreateTimeEntries < ActiveRecord::Migration[8.1]
  def change
    create_table :time_entries do |t|
      t.references :workspace, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.references :project, foreign_key: true
      t.references :task, foreign_key: true
      t.text :description
      t.datetime :started_at, null: false
      t.datetime :stopped_at
      t.integer :duration_seconds, null: false, default: 0
      t.boolean :billable, null: false, default: true
      t.integer :hourly_rate_cents

      t.timestamps
    end
    add_index :time_entries, [ :workspace_id, :user_id, :started_at ]
    add_index :time_entries, [ :workspace_id, :started_at ]
    add_index :time_entries, [ :user_id, :stopped_at ]
  end
end
