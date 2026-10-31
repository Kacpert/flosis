# Approving a project's setup run: wip/setup is merged into master, master is
# tagged approved/setup/<n>, and GitHub gets master and the tag in one atomic
# push that also deletes wip/setup there (Ruling P5-R7): a run started later
# begins on a fresh wip/setup from master, which a surviving remote branch
# would prevent. As for a task (Ruling P2-R24), nothing is kept here until the
# push is through, and the run is marked approved, its local branch and
# worktree removed and master published only after it.
class Designs::SetupApproval
  PREVIEW_NOT_UPDATED = Designs::Approval::PREVIEW_NOT_UPDATED

  def initialize(project, user:, wait: true)
    @project = project
    @user = user
    @wait = wait
  end

  # The version number of the approval.
  def approve!
    repo.synchronize(wait: @wait) do
      refuse_while_turns_run!
      setup = @project.design_setups.active.order(:id).last
      raise Designs::Approval::NothingToApprove, "the project has no setup run" unless setup

      repo.ensure_clone!
      raise Designs::Approval::NothingToApprove, "#{wip} has nothing to approve" unless repo.head(wip)

      number = next_number
      push_approval!(Designs::BranchNames.approval_tag("setup", number))
      setup.update!(status: "approved", approved_at: Time.current)
      message = note("Setup approved as version #{number}.")
      forget_wip
      publish!(message)
      number
    end
  end

  private

  def repo
    @repo ||= Designs::Repo.new(@project)
  end

  def wip
    Designs::BranchNames::SETUP
  end

  def refuse_while_turns_run!
    active = DesignTurn.active.joins(:chat_session)
                       .where(chat_sessions: { project_id: @project.id, purpose: "designs_setup" }).exists?
    raise Designs::Approval::TurnActive, "a setup turn is still queued or running" if active
  end

  def next_number
    repo.tags(Designs::BranchNames.approval_tag("setup", "*")).map { |tag| tag.split("/").last.to_i }.max.to_i + 1
  end

  def push_approval!(tag)
    master = repo.merge_into_master!(wip, message: "Approve setup")
    repo.tag!(tag, at: master)
    deletion = (":refs/heads/#{wip}" if repo.remote_head(wip))
    repo.push!(Designs::Repo::MASTER, tag, *deletion, atomic: true)
  rescue Designs::Repo::NothingToMerge
    raise Designs::Approval::NothingToApprove, "#{Designs::Repo::MASTER} already has everything on #{wip}"
  rescue StandardError
    roll_back!(tag)
    raise
  end

  def roll_back!(tag)
    repo.delete_tag!(tag) if repo.tags(tag).any?
    repo.reset_master!
  rescue StandardError => e
    Rails.logger.error("[#{self.class.name}] project #{@project.id}: could not undo a failed approval: #{e.class}: #{e.message}")
  end

  # The run is over here too: its worktree and branch go, so the next run's
  # first turn starts wip/setup afresh from master.
  def forget_wip
    path = repo.worktree_path(wip)
    repo.remove_worktree!(path) if path.exist?
    repo.delete_branch!(wip) if repo.head(wip)
  end

  def publish!(message)
    Designs::Publisher.new(@project, repo).publish!(Designs::Repo::MASTER, Designs::Repo::MASTER)
  rescue StandardError => e
    Rails.logger.error("[#{self.class.name}] project #{@project.id}: approved, but not published: #{e.class}: #{e.message}")
    message&.update!(content: "#{message.content} #{PREVIEW_NOT_UPDATED}")
  end

  def note(text)
    ChatSession.active.where(project: @project, purpose: "designs_setup").order(created_at: :desc).first
               &.chat_messages&.create!(role: "assistant", kind: "system", content: text)
  end
end
