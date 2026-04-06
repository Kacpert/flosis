class CreateFeedbackMeetings < ActiveRecord::Migration[8.1]
  def change
    create_table :feedback_meetings do |t|
      t.references :workspace, null: false, foreign_key: true
      t.references :creator, null: false, foreign_key: { to_table: :users }
      t.references :employee, null: false, foreign_key: { to_table: :users }
      t.string :title, null: false
      t.datetime :scheduled_at, null: false
      t.text :notes
      t.boolean :notes_visible, default: false, null: false
      t.timestamps
    end

    add_index :feedback_meetings, [:workspace_id, :employee_id]
    add_index :feedback_meetings, [:workspace_id, :scheduled_at]
  end
end
