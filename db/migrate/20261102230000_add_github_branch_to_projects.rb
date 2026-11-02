# The branch of the project's repository the server checks out and the AI
# reads. Blank: the repository's default branch, which is what every checkout
# got until now.
class AddGithubBranchToProjects < ActiveRecord::Migration[8.1]
  def change
    add_column :projects, :github_branch, :string
  end
end
