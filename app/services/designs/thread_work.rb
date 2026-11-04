# What a thread put on master (Designs imports): of the lines an update would
# take away or rewrite, those whose last change came from a thread's merge,
# or from a commit nobody can place (a person committing on GitHub, say),
# rather than from Flosis's own import, setup or start of the repository.
# Whatever it finds, the update waits for the person's Accept: an import
# never replaces a design approved in a thread by itself. When in doubt, it
# asks.
class Designs::ThreadWork
  def initialize(repo, project)
    @repo = repo
    @project = project
  end

  # [{ path:, merge: }] for each file whose thread-made lines the change from
  # base to head would replace; merge is the thread's DesignMerge, nil for a
  # commit nobody can place.
  def touched(base:, head:)
    @repo.diff_hunks(base, head).flat_map do |path, ranges|
      @repo.blame_commits(base, path, ranges).reject { |sha| own?(sha) }.map { |sha| { path: path, merge: merge_for(sha) } }
    end.uniq
  end

  private

  # A commit Flosis made for an import (each setup turn's, "setup: …") or
  # when it started the repository.
  def own?(sha)
    (@own ||= {}).fetch(sha) do
      subject = @repo.commit_subject(sha)
      @own[sha] = subject.start_with?("setup: ") || subject == Designs::InitializeRepoJob::COMMIT_MESSAGE
    end
  end

  def merge_for(sha)
    @merges ||= @project.design_merges.where.not(design_thread_id: nil).order(:merged_at).each_with_object({}) do |merge, found|
      @repo.merged_commits(merge.sha).each { |commit| found[commit] ||= merge }
    end
    @merges[sha]
  end
end
