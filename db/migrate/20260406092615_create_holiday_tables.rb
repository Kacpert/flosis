class CreateHolidayTables < ActiveRecord::Migration[8.1]
  def change
    create_table :holiday_requests do |t|
      t.references :user, null: false, foreign_key: true
      t.references :workspace, null: false, foreign_key: true
      t.date :start_date, null: false
      t.date :end_date, null: false
      t.integer :business_days, null: false
      t.text :note
      t.integer :status, null: false, default: 0
      t.references :reviewed_by, foreign_key: { to_table: :users }
      t.datetime :reviewed_at

      t.timestamps
    end

    add_index :holiday_requests, [:workspace_id, :user_id]
    add_index :holiday_requests, [:workspace_id, :status]
    add_index :holiday_requests, [:user_id, :start_date, :end_date]

    create_table :holiday_balance_entries do |t|
      t.references :user, null: false, foreign_key: true
      t.references :workspace, null: false, foreign_key: true
      t.integer :entry_type, null: false
      t.integer :days, null: false
      t.text :note
      t.references :holiday_request, foreign_key: true
      t.references :created_by, foreign_key: { to_table: :users }

      t.timestamps
    end

    add_index :holiday_balance_entries, [:workspace_id, :user_id]
    add_index :holiday_balance_entries, [:user_id, :entry_type]
  end
end
