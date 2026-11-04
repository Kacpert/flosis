# Designs imports (final review C2): the features and imports from before the
# imports existed have no review and no app commits, which the pages and the
# job read as an empty hash and an empty list.
class BackfillImportJsonColumns < ActiveRecord::Migration[8.1]
  def up
    execute "UPDATE design_setup_features SET review = '{}' WHERE review IS NULL"
    execute "UPDATE design_setups SET app_commits = '[]' WHERE app_commits IS NULL"
  end

  def down; end
end
