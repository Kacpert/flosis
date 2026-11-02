class CreateAlertRuns < ActiveRecord::Migration[8.1]
  def change
    create_table :alert_runs do |t|
      t.references :alert_rule, null: false, foreign_key: true
      t.boolean :fired, null: false, default: false
      t.string  :summary
      t.text    :detail
      t.string  :status, null: false, default: "ok" # ok|error
      t.datetime :ran_at, null: false
      t.timestamps
    end
  end
end
