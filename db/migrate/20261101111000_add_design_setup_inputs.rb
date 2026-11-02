# What a setup run (a project's first designs, made from the running app)
# starts from, kept for Flosis staff: the app's URL, the roles to log in as,
# the Figma files to read, and uploaded materials (Active Storage).
#
# design_setup_roles is one login: a name ("Admin"), the login page, the
# username, and the password, which the model encrypts and nothing ever shows
# back. position orders the roles as staff listed them.
#
# projects.design_figma_urls is JSON with no default, which MySQL could not
# give it; Project defaults it to [].
#
# Guarded per statement: MySQL commits DDL outside the migration transaction,
# so a failure part-way must leave a re-runnable state. There a create_table is
# one CREATE TABLE with its indexes and foreign keys inside it.
class AddDesignSetupInputs < ActiveRecord::Migration[8.1]
  def up
    unless table_exists?(:design_setup_roles)
      create_table :design_setup_roles do |t|
        t.references :project, null: false, foreign_key: true
        t.string :name, null: false
        t.string :login_url, null: false
        t.string :username, null: false
        t.text :password, null: false
        t.text :notes
        t.integer :position, default: 0, null: false
        t.timestamps
      end
    end

    add_column :projects, :design_app_url, :string unless column_exists?(:projects, :design_app_url)
    add_column :projects, :design_figma_urls, :json unless column_exists?(:projects, :design_figma_urls)
  end

  def down
    remove_column :projects, :design_figma_urls if column_exists?(:projects, :design_figma_urls)
    remove_column :projects, :design_app_url if column_exists?(:projects, :design_app_url)
    drop_table :design_setup_roles if table_exists?(:design_setup_roles)
  end
end
