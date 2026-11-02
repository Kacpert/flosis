require "test_helper"

# The branch is handed to git as an argument, so it has to look like a branch:
# one starting with a dash would be read as an option.
class ProjectGithubBranchTest < ActiveSupport::TestCase
  setup { @project = projects(:jira_project) }

  test "a blank branch means the repository's default" do
    @project.update!(github_branch: "  ")
    assert_nil @project.github_branch
  end

  test "an ordinary branch name is kept" do
    @project.update!(github_branch: " release/2026-11 ")
    assert_equal "release/2026-11", @project.github_branch
  end

  test "something git would read as an option is refused" do
    @project.github_branch = "--upload-pack=touch /tmp/x"
    assert_not @project.valid?
    assert_includes @project.errors[:github_branch], "is not a branch name"
  end
end
