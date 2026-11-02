class CreateProjectMemberships < ActiveRecord::Migration[8.1]
  def change
    create_table :project_memberships do |t|
      t.references :project, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.integer :hourly_rate_cents, null: false, default: 0

      t.timestamps
    end

    add_index :project_memberships, [:project_id, :user_id], unique: true
  end
end
