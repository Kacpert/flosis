class CreateJiraBoardTables < ActiveRecord::Migration[8.1]
  def change
    create_table :jira_boards do |t|
      t.references :project, null: false, foreign_key: true
      t.integer :jira_board_id, null: false
      t.string :name, null: false
      t.string :board_type, null: false
      t.timestamps
    end
    add_index :jira_boards, [:project_id, :jira_board_id], unique: true

    create_table :jira_sprints do |t|
      t.references :jira_board, null: false, foreign_key: true
      t.integer :jira_sprint_id, null: false
      t.string :name, null: false
      t.string :state, null: false
      t.datetime :start_date
      t.datetime :end_date
      t.timestamps
    end
    add_index :jira_sprints, [:jira_board_id, :jira_sprint_id], unique: true

    create_table :jira_board_columns do |t|
      t.references :jira_board, null: false, foreign_key: true
      t.string :name, null: false
      t.integer :position, null: false
      t.timestamps
    end
    add_index :jira_board_columns, [:jira_board_id, :position], unique: true

    create_table :jira_board_column_statuses do |t|
      t.references :jira_board_column, null: false, foreign_key: true
      t.string :jira_status_name, null: false
      t.string :jira_status_id, null: false
      t.timestamps
    end
    add_index :jira_board_column_statuses, [:jira_board_column_id, :jira_status_id],
              unique: true, name: "idx_board_col_statuses_on_col_and_status"
  end
end
