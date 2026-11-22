# What an import leaves for the person (Kacper, 2026-11-22: "może
# zasugerować jeżeli czegoś potrzebuje od usera ... jak AI nie miało danej
# roli czy coś"): a role the setup lacks, a context that could not sign in,
# anything else only the person can give. Shown as Feedback once the import
# is over, with actions that import more.
class CreateDesignImportSuggestions < ActiveRecord::Migration[8.1]
  def change
    create_table :design_import_suggestions do |t|
      t.references :design_setup, null: false, foreign_key: { on_delete: :cascade }
      t.string :kind, null: false
      t.string :key, null: false
      t.string :title, null: false
      t.text :detail
      t.string :context_name
      t.references :design_setup_role, foreign_key: { on_delete: :nullify }
      t.json :features
      t.string :status, null: false, default: "open"
      t.references :acted_by, foreign_key: { to_table: :users, on_delete: :nullify }
      t.datetime :acted_at
      t.timestamps
    end
    add_index :design_import_suggestions, %i[design_setup_id key], unique: true
  end
end
