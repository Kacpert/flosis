class CreateIntegrations < ActiveRecord::Migration[8.1]
  def change
    create_table :integrations do |t|
      t.references :workspace, null: false, foreign_key: true
      t.string :provider, null: false
      t.jsonb :config, null: false, default: {}
      t.boolean :active, null: false, default: false

      t.timestamps
    end
  end
end
