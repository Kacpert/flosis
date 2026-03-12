class CreateTasks < ActiveRecord::Migration[8.1]
  def change
    create_table :tasks do |t|
      t.references :project, null: false, foreign_key: true
      t.string :name, null: false
      t.boolean :billable
      t.integer :hourly_rate_cents
      t.integer :status, null: false, default: 0
      t.string :external_reference
      t.string :external_type
      t.string :external_url

      t.timestamps
    end
    add_index :tasks, [ :project_id, :name ], unique: true
  end
end
