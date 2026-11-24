# Kacper, 2026-11-24: the designs are HTML and CSS, with no framework to pick
# (React, Vue and Angular are gone from the setup form), so a project keeps
# none. Every project held "html".
class RemoveDesignsFrameworkFromProjects < ActiveRecord::Migration[8.1]
  def change
    remove_column :projects, :designs_framework, :string, default: "html", null: false
    remove_column :projects, :designs_framework_version, :string
  end
end
