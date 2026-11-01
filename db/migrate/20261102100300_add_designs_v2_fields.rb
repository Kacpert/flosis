# What Workshop Designs v2 adds to existing tables: the project's stack and app
# repositories (the setup form), structured data on chat messages (chips,
# description diffs, merges that came in) and the setup run's steps.
class AddDesignsV2Fields < ActiveRecord::Migration[8.1]
  def change
    add_column :projects, :designs_framework, :string, null: false, default: "html"
    add_column :projects, :designs_framework_version, :string
    add_column :projects, :designs_ui_system, :string, null: false, default: "tailwind"
    add_column :projects, :designs_ui_version, :string, default: "4"
    add_column :projects, :design_app_repos, :json

    add_column :chat_messages, :data, :json

    add_column :design_setups, :step, :integer, null: false, default: 0
    add_column :design_setups, :error, :text
    add_column :design_setups, :finished_at, :datetime
    add_column :design_setups, :pages, :integer
    add_reference :design_setups, :design_thread, foreign_key: { on_delete: :nullify }
  end
end
