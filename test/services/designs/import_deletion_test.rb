require "test_helper"

# Deleting an import that stopped before any of it reached master (Kacper,
# 2026-11-22: "ten najnowszy trzeba zatrzymać i usunąć"): its features'
# branches go, here and on GitHub, with its chats, its run folder and the
# import itself. Only a stopped or failed resync with nothing on master may go.
class Designs::ImportDeletionTest < ActiveSupport::TestCase
  include DesignRepoTestHelper

  def resync(project, **more)
    project.design_setups.create!({ kind: "resync", status: "failed", phase: "feature", step: 3, started_by: users(:one),
                                    stopped_at: 1.minute.ago, stopped_by: users(:one) }.merge(more))
  end

  test "deleting an import removes its branches, chats, run folder and record" do
    with_design_remote do |repo, remote|
      with_remote_url(remote) do
        seed_master(repo)
        project = repo.project
        setup = resync(project)
        feature = setup.features.create!(name: "Designs", key: "designs", position: 1, status: "failed", branch: "wip/import-#{setup.id}-designs")
        dir = repo.worktree!(feature.branch, from: "master")
        commit_files(repo, dir, { "designs/admin/designs.html" => "<h1>Designs</h1>" })
        repo.push!(feature.branch)
        session = ChatSession.create!(project: project, workspace: project.workspace, user: users(:one), purpose: "designs_setup",
                                      claude_session_id: SecureRandom.uuid, codebase_path: "/tmp", design_setup: setup)
        message = session.chat_messages.create!(role: "user", user: users(:one), content: "Build it.")
        DesignTurn.create!(chat_session: session, chat_message: message, kind: "setup", status: "failed")
        FileUtils.mkdir_p(setup.run_dir.join("auth"))
        File.write(setup.run_dir.join("auth", "1-admin.json"), "{}")

        Designs::ImportDeletion.new(setup).delete!

        refute DesignSetup.exists?(setup.id)
        refute DesignSetupFeature.exists?(feature.id)
        refute ChatSession.exists?(session.id)
        assert_nil repo.head(feature.branch)
        refute repo.worktree_path(feature.branch).exist?
        assert_nil remote_branch_sha(remote, feature.branch)
        refute setup.run_dir.exist?
        assert repo.head("master")
      end
    end
  end

  test "only a stopped or failed resync with nothing on master may be deleted" do
    project = projects(:jira_project)
    assert resync(project).deletable?
    assert resync(project, stopped_at: nil, stopped_by: nil, error: "No app repository could be read.").deletable?
    refute resync(project, status: "active", stopped_at: nil).deletable?
    refute resync(project, status: "approved", stopped_at: nil, finished_at: Time.current).deletable?
    refute project.design_setups.create!(status: "failed", phase: "map", step: 2, started_by: users(:one)).deletable?

    landed = resync(project)
    landed.features.create!(name: "Library", key: "library", position: 1, status: "done")
    refute landed.deletable?
  end

  # Final review (re-graded): a branch GitHub no longer has does not stop
  # the deletion halfway.
  test "a branch already gone from GitHub does not stop the deletion" do
    with_design_remote do |repo, remote|
      with_remote_url(remote) do
        seed_master(repo)
        setup = resync(repo.project)
        feature = setup.features.create!(name: "Designs", key: "designs", position: 1, status: "failed", branch: "wip/import-#{setup.id}-designs")
        commit_files(repo, repo.worktree!(feature.branch, from: "master"), { "designs/admin/designs.html" => "<h1>Designs</h1>" })
        repo.push!(feature.branch)
        system("git", "--git-dir", remote, "branch", "-D", feature.branch, out: File::NULL, exception: true)
        # GitHub refuses to delete a branch it does not have; a local remote
        # only warns, so a hook stands in for GitHub's refusal.
        hook = File.join(remote, "hooks", "pre-receive")
        File.write(hook, "#!/bin/sh\nwhile read old new ref; do\n  [ \"$old\" = \"$new\" ] && { echo \"remote ref does not exist\" >&2; exit 1; }\ndone\nexit 0\n")
        File.chmod(0o755, hook)

        Designs::ImportDeletion.new(setup).delete!
        refute DesignSetup.exists?(setup.id)
        assert_nil repo.head(feature.branch)
      end
    end
  end
end
