class AddCurrencyToProjects < ActiveRecord::Migration[8.1]
  def change
    add_column :projects, :currency, :string, limit: 3, default: "USD", null: false
  end
end
