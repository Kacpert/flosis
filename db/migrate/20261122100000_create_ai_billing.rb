# SCRUM-70: every Claude run is recorded and priced (ai_runs), against plans
# Flosis staff make (ai_plans, ai_plan_models), with a reference price list
# (ai_models) and each month's limit frozen once it closes (ai_month_limits).
# All money is in US dollars.
class CreateAiBilling < ActiveRecord::Migration[8.1]
  def change
    create_table :ai_plans do |t|
      t.string :name, null: false
      t.decimal :monthly_price_usd, precision: 12, scale: 2, null: false
      t.decimal :margin_percent, precision: 6, scale: 2, null: false
      t.timestamps
    end

    create_table :ai_models do |t|
      t.string :model_id, null: false
      t.string :name, null: false
      t.decimal :input_usd_per_mtok, precision: 12, scale: 4
      t.decimal :output_usd_per_mtok, precision: 12, scale: 4
      t.decimal :cache_write_usd_per_mtok, precision: 12, scale: 4
      t.decimal :cache_read_usd_per_mtok, precision: 12, scale: 4
      t.string :price_source, null: false, default: "read"
      t.datetime :read_at
      t.datetime :read_failed_at
      t.datetime :hand_set_at
      t.timestamps
      t.index :model_id, unique: true
    end

    create_table :ai_plan_models do |t|
      t.references :ai_plan, null: false, foreign_key: true, index: false
      t.references :ai_model, null: false, foreign_key: true
      t.timestamps
      t.index [ :ai_plan_id, :ai_model_id ], unique: true
    end

    change_table :workspaces, bulk: true do |t|
      t.references :ai_plan, foreign_key: true
      t.datetime :ai_plan_assigned_at
      t.boolean :ai_costs_enabled, null: false, default: true
    end

    add_column :users, :show_ai_costs, :boolean, null: false, default: false

    create_table :ai_runs do |t|
      t.references :workspace, null: false, foreign_key: true, index: false
      # A deleted project's runs stay in the organization's totals.
      t.references :project, foreign_key: { on_delete: :nullify }, index: false
      t.string :project_name
      t.string :area, null: false
      # No foreign key: a deleted item leaves its runs where they were counted.
      t.string :item_type
      t.bigint :item_id
      t.string :item_label
      t.references :started_by, foreign_key: { to_table: :users, on_delete: :nullify }
      t.string :automation
      t.string :status, null: false, default: "running"
      t.string :model
      t.jsonb :model_usage
      t.bigint :input_tokens, null: false, default: 0
      t.bigint :output_tokens, null: false, default: 0
      t.bigint :cache_write_tokens, null: false, default: 0
      t.bigint :cache_read_tokens, null: false, default: 0
      # nil = the run reported no cost: unknown, never counted as 0.
      t.decimal :cost_usd, precision: 14, scale: 6
      t.decimal :margin_percent, precision: 6, scale: 2
      t.decimal :price_usd, precision: 14, scale: 6
      t.boolean :own_key, null: false, default: false
      t.string :claude_session_id
      t.datetime :ran_at, null: false
      t.integer :duration_ms
      t.datetime :unknown_reviewed_at
      t.references :unknown_reviewed_by, foreign_key: { to_table: :users, on_delete: :nullify }, index: false
      t.timestamps

      t.index [ :workspace_id, :ran_at ]
      t.index [ :workspace_id, :area, :ran_at ]
      t.index [ :project_id, :ran_at ]
      t.index [ :item_type, :item_id ]
      t.index :workspace_id, where: "cost_usd IS NULL", name: "index_ai_runs_unknown_cost"
      t.index :ran_at, where: "status = 'running'", name: "index_ai_runs_running"
    end

    create_table :ai_month_limits do |t|
      t.references :workspace, null: false, foreign_key: true, index: false
      t.date :month, null: false
      t.references :ai_plan, foreign_key: { on_delete: :nullify }
      t.string :plan_name
      t.decimal :limit_usd, precision: 12, scale: 2
      t.timestamps
      t.index [ :workspace_id, :month ], unique: true
    end
  end
end
