# One feature of an import landing on master by itself (Designs imports): a
# feature built after the import (retried, answered, added, or brought by a
# resync) is merged from its own branch into master as it finishes, recorded
# as an import merge, so that open threads learn of it through the "master
# changed" banner and Merge history lists it. As a thread's merge
# (Designs::Threads.merge!), the merge is made and pushed under the repo's
# lock, with the branch's deletion on GitHub in the same atomic push; a push
# GitHub refuses puts master back. Then the branch goes here too and master
# is published.
#
# An update that would replace a thread's work on master (Designs::ThreadWork)
# does not land: it raises NeedsReview, and the person's Accept lands it.
class Designs::ImportLanding
  CONFLICT = "Couldn't land on master: master changed the same files while it was built. Retry builds it again from master.".freeze

  # GitHub took nothing: master is put back, and the branch keeps the work.
  class NotLanded < StandardError; end

  # The update would replace what a thread put on master.
  class NeedsReview < StandardError
    attr_reader :touched

    def initialize(touched)
      @touched = touched
      super("it would replace a thread's work on master")
    end
  end

  def initialize(feature)
    @feature = feature
    @setup = feature.design_setup
    @project = @setup.project
    @repo = Designs::Repo.new(@project)
  end

  # The merge, or nil when the branch has nothing master lacks (the feature
  # already matched it). Raises Designs::Repo::Conflict, master untouched,
  # when the branch does not merge cleanly, and NeedsReview, unless accepted,
  # when it would replace a thread's work.
  def land!(accepted: false)
    branch = @feature.branch
    merge = @repo.synchronize do
      @repo.ensure_clone!
      next unless @repo.head(branch)

      @repo.follow_origin!(branch)
      commits = @repo.commits_ahead(branch)
      next unless commits.positive?

      unless accepted
        base = @repo.merge_base(branch, Designs::Repo::MASTER)
        touched = Designs::ThreadWork.new(@repo, @project).touched(base: base, head: "refs/heads/#{branch}")
        raise NeedsReview, touched if touched.any?
      end

      screens = changed_screens(branch)
      sha = @repo.merge_into_master!(branch, message: "Import: #{@feature.name}")
      deletion = (":refs/heads/#{branch}" if @repo.remote_head(branch))
      begin
        @repo.push!(Designs::Repo::MASTER, *deletion, atomic: true)
      rescue StandardError => e
        @repo.reset_master!
        raise NotLanded, "Couldn't land on master: #{(e.message.presence || e.class.name).lines.last.to_s.strip.delete_suffix('.').truncate(300)}."
      end
      record!(sha, branch, screens, commits)
    end
    forget!(branch)
    publish_master! if merge
    merge
  end

  # A proposal let go (Reject): its branch goes here and on GitHub, and its
  # preview with it.
  def discard!
    branch = @feature.branch or return
    @repo.synchronize do
      @repo.ensure_clone!
      path = @repo.worktree_path(branch)
      @repo.remove_worktree!(path) if path.exist?
      @repo.delete_branch!(branch) if @repo.head(branch)
      @repo.push!(":refs/heads/#{branch}") if @repo.remote_head(branch)
    end
    Designs::Publisher.new(@project, @repo).unpublish!(branch)
  end

  private

  def changed_screens(branch)
    base = @repo.merge_base(branch, Designs::Repo::MASTER)
    at = ->(ref) { Designs::Screens.new(paths: @repo.ls_files(ref, "designs/"), reader: ->(path) { @repo.read_file(ref, path) }) }
    before = base ? at.call(base) : Designs::Screens.new(paths: [], reader: ->(_path) { nil })
    Designs::Changes.new(base: before, head: at.call(branch)).changed.map { |change| "#{change[:context]}/#{change[:screen]}" }
  end

  def record!(sha, branch, screens, commits)
    summary = @feature.design_turn&.chat_session&.chat_messages&.where(role: "assistant", kind: "summary")&.order(:id)&.last&.content
    @project.design_merges.create!(sha: sha, title: @feature.name, branch: branch, how: "import", screens: screens,
                                   commits: [ commits, 1 ].max, summary: summary.presence || "#{@feature.name}, built from the app.",
                                   what_changed: [ "#{@feature.name} · #{@setup.title}" ], merged_at: Time.current)
  end

  # The branch is done with: its worktree, its local ref and its preview go.
  def forget!(branch)
    @repo.synchronize do
      path = @repo.worktree_path(branch)
      @repo.remove_worktree!(path) if path.exist?
      @repo.delete_branch!(branch) if @repo.head(branch) && @repo.commits_ahead(branch).zero?
    end
    Designs::Publisher.new(@project, @repo).unpublish!(branch)
  rescue StandardError => e
    Rails.logger.warn("[#{self.class.name}] #{branch}: could not tidy up after landing: #{e.class}: #{e.message}")
  end

  def publish_master!
    Designs::Publisher.new(@project, @repo).publish!(Designs::Repo::MASTER, Designs::Repo::MASTER)
  rescue StandardError => e
    Rails.logger.error("[#{self.class.name}] project #{@project.id}: landed, but master was not published: #{e.class}: #{e.message}")
  end
end
