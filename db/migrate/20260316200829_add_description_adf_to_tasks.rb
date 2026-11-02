class AddDescriptionAdfToTasks < ActiveRecord::Migration[8.1]
  def change
    add_column :tasks, :description_adf, :text
  end
end
