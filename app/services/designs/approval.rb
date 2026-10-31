# Approving a task's designs into master, and bringing its working branch up
# to date with master when the two have moved apart.
#
# An approval merges the working branch into master, points the task's design
# branch at the work that was approved and tags master approved/<KEY>/<n>.
# GitHub gets all three in one atomic push, and only then does Flosis keep the
# approval and publish it: the design branch is what Jira links to, and master
# is what every later task starts from.
#
# Both run under the repo's lock, and neither while a turn of the task is
# queued or running: a turn edits the worktree, and its commit would land
# after what was approved, or on top of a merge it never saw.
class Designs::Approval
  # The working branch has nothing that master and the design branch lack.
  class NothingToApprove < StandardError; end

  # A turn of the task is queued or running.
  class TurnActive < StandardError; end

  # What the approval's chat message adds when the preview could not be
  # updated. What the publish failed on can name the preview folder, so it
  # goes to the log only.
  PREVIEW_NOT_UPDATED = "The preview could not be updated, so it still shows the version before.".freeze

  # With wait: false a repo whose lock another holds raises Repo::Busy at
  # once: a web request must not wait behind a job.
  def initialize(task, user:, wait: true)
    @task = task
    @user = user
    @wait = wait
  end

  def approve!
    repo.synchronize(wait: @wait) do
      refuse_while_turns_run!
      repo.ensure_clone!
      work = repo.head(wip)
      raise NothingToApprove, "#{wip} has nothing new to approve" if work.nil? || work == repo.head(design)

      number = next_number
      tag = Designs::BranchNames.approval_tag(slug, number)
      master = push_approval!(work, tag)
      approval, message = record!(number, tag, work, master)
      publish!(message)
      approval
    end
  end

  # :merged once master is merged into the working branch and the result is
  # pushed and published. When master changed the same files, nothing of the
  # merge is kept: a resolve_conflicts turn merges again and has Claude
  # resolve the markers, and :resolving is returned.
  def update_from_master!
    repo.synchronize(wait: @wait) do
      refuse_while_turns_run!
      repo.ensure_clone!
      # A task no turn has worked on yet will start from master as it is.
      next :merged unless repo.head(wip) || repo.remote_head(wip)

      dir = repo.worktree!(wip)
      # With no turn running, anything uncommitted here is what a killed turn
      # left.
      repo.discard!(dir)
      conflicts = repo.merge_master_into!(dir)
      if conflicts.empty?
        repo.push!(wip) if repo.unpushed?(wip)
        Designs::Publisher.new(@task.project, repo).publish!(wip, "wip/#{slug}") if repo.commits_ahead(wip).positive?
        :merged
      else
        # The markers must not wait in the worktree: a turn queued before the
        # resolving one would commit them.
        repo.discard!(dir)
        start_resolving!(conflicts)
        :resolving
      end
    end
  end

  private

  def repo
    @repo ||= Designs::Repo.new(@task.project)
  end

  def slug
    @slug ||= Designs::BranchNames.slug(@task)
  end

  def wip
    Designs::BranchNames.wip(@task)
  end

  def design
    Designs::BranchNames.design(@task)
  end

  def session
    @session ||= ChatSession.designs_for!(@task, user: @user, codebase_path: repo.worktree_path(wip).to_s)
  end

  # Checked under the repo's lock: a turn takes the lock to check its worktree
  # out only after it is marked running, so one that starts later waits for
  # this to finish.
  def refuse_while_turns_run!
    return unless DesignTurn.active.joins(:chat_session).where(chat_sessions: { task_id: @task.id }).exists?

    raise TurnActive, "a turn of #{slug} is still queued or running"
  end

  # One past the highest number taken, by a tag or by a record: a tag deleted
  # on GitHub must not hand out a number an approval already has.
  def next_number
    tagged = repo.tags(Designs::BranchNames.approval_tag(slug, "*")).map { |tag| tag.split("/").last.to_i }
    [ *tagged, @task.design_approvals.maximum(:number) ].compact.max.to_i + 1
  end

  # master's sha once the work is merged into it, the design branch points at
  # the work and the tag at master, all three on GitHub. Until that push is
  # through nothing of it is kept here either: a design branch left at the
  # work would make every retry "nothing to approve", and a tag that never
  # went out would take its number.
  def push_approval!(work, tag)
    design_was = repo.head(design)
    master = repo.merge_into_master!(wip, message: "Approve #{slug}")
    repo.point!(design, to: work)
    repo.tag!(tag, at: master)
    repo.push!(design, Designs::Repo::MASTER, tag, atomic: true)
    master
  rescue Designs::Repo::NothingToMerge
    raise NothingToApprove, "#{Designs::Repo::MASTER} already has everything on #{wip}"
  rescue StandardError
    roll_back!(design_was, tag)
    raise
  end

  def roll_back!(design_was, tag)
    repo.delete_tag!(tag) if repo.tags(tag).any?
    if design_was
      repo.point!(design, to: design_was)
    elsif repo.head(design)
      repo.delete_branch!(design)
    end
    repo.reset_master!
  rescue StandardError => e
    Rails.logger.error("[#{self.class.name}] #{slug}: could not undo a failed approval: #{e.class}: #{e.message}")
  end

  def record!(number, tag, work, master)
    DesignApproval.transaction do
      approval = @task.design_approvals.create!(user: @user, number: number, tag: tag, design_sha: work, master_sha: master)
      message = session.chat_messages.create!(role: "assistant", kind: "system", content: "Approved as version #{number}.")
      [ approval, message ]
    end
  end

  # The approval stands whatever happens here: it is on GitHub already.
  def publish!(message)
    publisher = Designs::Publisher.new(@task.project, repo)
    publisher.publish!(design, slug)
    publisher.publish!(Designs::Repo::MASTER, Designs::Repo::MASTER)
  rescue StandardError => e
    Rails.logger.error("[#{self.class.name}] #{slug}: approved, but not published: #{e.class}: #{e.message}")
    message.update!(content: "#{message.content} #{PREVIEW_NOT_UPDATED}")
  end

  def start_resolving!(paths)
    turn = DesignTurn.transaction do
      session.chat_messages.create!(
        role: "assistant", kind: "system",
        content: "Master changed the same files as this task: #{paths.join(", ")}. Claude is resolving the conflicts."
      )
      request = session.chat_messages.create!(role: "user", user: @user, content: DesignTurn.resolve_request(paths))
      DesignTurn.create!(chat_session: session, chat_message: request, kind: "resolve_conflicts")
    end
    Designs::TurnJob.perform_later(turn.id)
  end
end
