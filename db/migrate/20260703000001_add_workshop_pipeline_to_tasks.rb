class AddWorkshopPipelineToTasks < ActiveRecord::Migration[8.1]
  def change
    add_column :tasks, :in_pipeline, :boolean, default: false, null: false
    add_column :tasks, :workshop_stage, :string, default: "new", null: false
    add_column :tasks, :pipeline_entered_at, :datetime
    add_reference :tasks, :pipeline_author, foreign_key: { to_table: :users }, null: true
    add_index :tasks, [:project_id, :in_pipeline, :workshop_stage]
  end
end
