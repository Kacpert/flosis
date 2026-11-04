require "test_helper"

# What a thread put on master (Designs imports): the lines an update from the
# app would change that came from a thread's merge, or from a commit nobody
# can place, rather than from an import, the setup or the repository's start.
class Designs::ThreadWorkTest < ActiveSupport::TestCase
  include DesignRepoTestHelper

  CARD = "<h1>Bugs</h1>\n<div class=\"card\">old card</div>\n<footer>Assign</footer>\n".freeze

  # master: the screen as an import made it, then a thread's redesign of its
  # card, merged and recorded.
  def master_with_a_thread(repo)
    repo.ensure_clone!
    commit_files(repo, repo.root, { Designs::Repo::RUNTIME => "// the runtime\n", "designs/admin/bugs.html" => CARD }, message: "setup: Add Bug Reporting")
    repo.push!("master")
    thread = repo.project.design_threads.create!(title: "Bug card v2", branch: "design/bug-card-v2", author: users(:one))
    dir = repo.worktree!(thread.branch, from: "master")
    commit_files(repo, dir, { "designs/admin/bugs.html" => CARD.sub("old card", "new card") }, message: "bug-card-v2: redesign the card")
    sha = repo.merge_into_master!(thread.branch, message: "Merge design/bug-card-v2: Bug card v2")
    repo.push!("master")
    repo.project.design_merges.create!(sha: sha, title: thread.title, branch: thread.branch, how: "manual", design_thread: thread, merged_at: Time.current)
  end

  def update(repo, files, message: "setup: Update Bug Reporting")
    branch = "wip/import-1-bug-reporting"
    commit_files(repo, repo.worktree!(branch, from: "master"), files, message: message)
    Designs::ThreadWork.new(repo, repo.project).touched(base: repo.head("master"), head: "refs/heads/#{branch}")
  end

  test "lines a thread put on master are its work" do
    with_design_remote do |repo, _remote|
      merge = master_with_a_thread(repo)
      touched = update(repo, { "designs/admin/bugs.html" => CARD.sub("old card", "the app's card") })
      assert_equal [ { path: "designs/admin/bugs.html", merge: merge } ], touched
    end
  end

  test "lines an import made are not" do
    with_design_remote do |repo, _remote|
      master_with_a_thread(repo)
      assert_empty update(repo, { "designs/admin/bugs.html" => CARD.sub("old card", "new card").sub("Assign", "Assign to me") })
    end
  end

  test "a line added beside a thread's does not change it" do
    with_design_remote do |repo, _remote|
      master_with_a_thread(repo)
      assert_empty update(repo, { "designs/admin/bugs.html" => CARD.sub("old card", "new card").sub("<footer>", "<p>Filter by status</p>\n<footer>") })
    end
  end

  test "a commit nobody can place counts as a thread's" do
    with_design_remote do |repo, _remote|
      repo.ensure_clone!
      commit_files(repo, repo.root, { Designs::Repo::RUNTIME => "// the runtime\n", "designs/admin/bugs.html" => CARD }, message: "Fix the card by hand")
      repo.push!("master")
      touched = update(repo, { "designs/admin/bugs.html" => CARD.sub("old card", "the app's card") })
      assert_equal [ { path: "designs/admin/bugs.html", merge: nil } ], touched
    end
  end
end
