# Deletes an import that stopped or failed before any of it reached master
# (Kacper, 2026-11-22: "ten najnowszy trzeba zatrzymać i usunąć";
# DesignSetup#deletable?). Its features' branches go, with their worktrees,
# here and on GitHub; then its chats (their turns and messages with them),
# the import itself (its features and views with it) and its run folder,
# which holds the app's copies and the contexts' signed-in states.
class Designs::ImportDeletion
  def initialize(setup)
    @setup = setup
    @project = setup.project
  end

  def delete!
    remove_branches!
    ActiveRecord::Base.transaction do
      ChatSession.where(design_setup_id: @setup.id).find_each(&:destroy!)
      @setup.destroy!
    end
    remove_run_dir!
  end

  private

  def remove_branches!
    names = @setup.features.flat_map { |feature| [ feature.branch.presence, Designs::BranchNames.import(feature) ] }.compact.uniq
    return if names.empty?

    repo = Designs::Repo.new(@project)
    return unless repo.initialized?

    repo.synchronize do
      names.each do |name|
        path = repo.worktree_path(name)
        repo.remove_worktree!(path) if path.exist?
        repo.delete_branch!(name) if repo.head(name)
        repo.push!(":refs/heads/#{name}") if repo.remote_head(name)
      end
    end
  end

  def remove_run_dir!
    dir = @setup.run_dir
    return unless dir.to_s.end_with?("/design-runs/#{@setup.id}") && dir.exist?

    FileUtils.chmod_R("u+w", dir)
    FileUtils.rm_rf(dir)
  end
end
