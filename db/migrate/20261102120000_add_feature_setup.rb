# The Designs setup, feature by feature: a setup run maps the app's features
# and builds them one after another. Each feature of the map is a row of its
# own (its status, notes and the turn that built it), the run keeps notes of
# its own and the time each finished step took, and a job claims each unit of
# the run until a deadline, so a run a deploy cut off can be picked up again.
class AddFeatureSetup < ActiveRecord::Migration[8.1]
  def change
    create_table :design_setup_features do |t|
      t.references :design_setup, null: false, foreign_key: true, index: false
      t.integer :position, null: false
      t.string :key, null: false
      t.string :name, null: false
      t.json :contexts
      t.json :screens
      t.text :brief
      t.string :status, null: false, default: "todo"
      t.string :stage
      t.json :notes
      t.integer :components_new, null: false, default: 0
      t.integer :components_reused, null: false, default: 0
      t.references :design_turn, foreign_key: { on_delete: :nullify }
      t.datetime :started_at
      t.datetime :finished_at
      t.text :error
      t.timestamps
    end
    add_index :design_setup_features, [ :design_setup_id, :position ], unique: true
    add_index :design_setup_features, [ :design_setup_id, :key ], unique: true

    add_column :design_setups, :notes, :json
    add_column :design_setups, :step_seconds, :json
    add_column :design_setups, :step_started_at, :datetime
    add_column :design_setups, :unit_job_id, :string
    add_column :design_setups, :unit_deadline_at, :datetime
  end
end
