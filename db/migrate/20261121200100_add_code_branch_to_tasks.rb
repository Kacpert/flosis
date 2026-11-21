# Finish creates a branch for the task in the app's repo (Kacper, 2026-11-21):
# the task remembers it, the commit it last wrote, when, and why the last try
# failed.
class AddCodeBranchToTasks < ActiveRecord::Migration[8.1]
  def change
    add_column :tasks, :code_branch, :string
    add_column :tasks, :code_branch_sha, :string
    add_column :tasks, :code_branch_pushed_at, :datetime
    add_column :tasks, :code_branch_error, :text
  end
end
