# Workshop Designs: a project can keep AI-made, clickable designs in a
# repository of its own, one branch per task. These are the settings that repo
# needs on the project.
#
# The repository's token is not github_token. It has to push, while the app
# repo's token only reads the application's code, so it gets its own column.
# It is text, like the other encrypted tokens: Active Record stores the
# ciphertext, which is the token plus about a hundred characters of envelope.
#
# design_preview_token is the unguessable segment of every preview link. It is
# nullable on purpose: a project gets one the first time it needs one, so every
# existing row stays NULL, and a unique index allows any number of those.
#
# design_repo_status and design_repo_error follow repo_checkout_status and
# repo_checkout_error: where the repo's setup stands, and why it stopped. The
# error is text, not a string like repo_checkout_error, because it keeps git's
# own message, and MySQL in strict mode refuses a string past 255 characters
# instead of cutting it.
#
# Guarded per statement: MySQL commits DDL outside the migration transaction,
# so a failure part-way must leave a re-runnable state.
class AddDesignSettingsToProjects < ActiveRecord::Migration[8.1]
  COLUMNS = [
    [ :designs_enabled, :boolean, { default: false, null: false } ],
    [ :design_repo, :string, {} ],
    [ :design_repo_token, :text, {} ],
    [ :design_base_kit, :string, { default: "tailwind4", null: false } ],
    [ :design_preview_token, :string, {} ],
    [ :design_repo_status, :string, {} ],
    [ :design_repo_error, :text, {} ]
  ].freeze

  def up
    COLUMNS.each do |name, type, options|
      next if column_exists?(:projects, name)
      add_column :projects, name, type, **options
    end

    unless index_exists?(:projects, :design_preview_token, unique: true)
      add_index :projects, :design_preview_token, unique: true
    end
  end

  def down
    if index_exists?(:projects, :design_preview_token, unique: true)
      remove_index :projects, :design_preview_token
    end

    COLUMNS.each { |name, _, _| remove_column :projects, name if column_exists?(:projects, name) }
  end
end
