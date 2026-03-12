class CreateProjects < ActiveRecord::Migration[8.1]
  def change
    create_table :projects do |t|
      t.references :workspace, null: false, foreign_key: true
      t.references :client, foreign_key: true
      t.string :name, null: false
      t.string :color, null: false, default: "#3B82F6", limit: 7
      t.boolean :billable, null: false, default: true
      t.boolean :archived, null: false, default: false
      t.integer :hourly_rate_cents
      t.integer :budget_cents
      t.integer :budget_type, null: false, default: 0
      t.decimal :budget_hours, precision: 10, scale: 2
      t.string :external_reference
      t.string :external_type

      t.timestamps
    end
    add_index :projects, [ :workspace_id, :name ]
    add_index :projects, [ :workspace_id, :client_id ]
  end
end
