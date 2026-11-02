class CreatePrReviews < ActiveRecord::Migration[8.1]
  def change
    create_table :pr_reviews do |t|
      t.references :workspace, null: false, foreign_key: true
      t.integer :pr_number, null: false
      t.string :last_reviewed_sha
      t.boolean :initial_done, null: false, default: false
      t.datetime :reviewed_at
      t.timestamps
    end
    add_index :pr_reviews, [ :workspace_id, :pr_number ], unique: true
  end
end
