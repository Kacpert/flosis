class CreateDesignRequests < ActiveRecord::Migration[8.1]
  def change
    create_table :design_requests do |t|
      t.references :task, null: false, foreign_key: true, index: { unique: true }
      t.references :requester, null: false, foreign_key: { to_table: :users }
      t.references :designer,  null: false, foreign_key: { to_table: :users }
      t.string  :status, null: false, default: "requested" # requested|delivered|cancelled
      t.text    :note
      # :json (NOT :jsonb) — MySQL in production supports JSON but not JSONB,
      # and MySQL JSON columns cannot carry a DB default, so the default ([])
      # is set on the model via `attribute :links, default: []` instead.
      t.json    :links
      t.datetime :delivered_at
      t.timestamps
    end
  end
end
