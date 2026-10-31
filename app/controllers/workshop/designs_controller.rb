# A task's Designs screen: a chat with Claude on the left, the preview of the
# task's designs on the right with its contexts, and in the top bar the count
# of what waits to be approved and the button that approves it into master.
#
# Each message starts a DesignTurn that Designs::TurnJob runs; the chat frame
# polls while one is queued or running. Requests never wait on the design
# repo's lock, which a job can hold for minutes: the screen reads refs without
# it, and approving or updating from master gives up at once when it is held.
class Workshop::DesignsController < Workshop::BaseController
  before_action { require_permission!(:tasks) }
  before_action :set_idea
  before_action :require_designs!

  NOT_SET_UP = "Designs isn't set up for this project — see Configuration › Designs.".freeze
  BUSY = "The design repo is busy — try again in a minute.".freeze
  CONFLICT = "Master has changed in the same files. Use “Update from master”, then approve again.".freeze

  def show
    DesignTurn.fail_stale!
    load_chat
    load_screen
  end

  def chat
    DesignTurn.fail_stale!
    load_chat
    render_chat
  end

  def message
    if ProjectCredentials.new(project).designs_api_key.nil?
      load_chat
      return render_chat(status: :unprocessable_entity)
    end

    content = params[:content].to_s.strip
    start_turn(content) if content.present?
    load_chat
    render_chat
  end

  def approve
    approval = Designs::Approval.new(@idea, user: current_user, wait: false).approve!
    back(toast: "Approved as version #{approval.number}.")
  rescue Designs::Approval::NothingToApprove
    back(alert: "Nothing new to approve.")
  rescue Designs::Repo::Conflict
    flash[:designs_update] = true
    back(alert: CONFLICT)
  rescue Designs::Approval::TurnActive
    back(alert: "Wait for the current turn to finish, then approve.")
  rescue Designs::Repo::Busy
    back(alert: BUSY)
  rescue StandardError => e
    report(e, "approving")
    back(alert: "The approval did not go through — try again in a minute.")
  end

  def update_from_master
    if Designs::Approval.new(@idea, user: current_user, wait: false).update_from_master! == :merged
      back(toast: "Brought up to date with master.")
    else
      back(toast: "Master changed the same files — Claude is resolving the conflicts.")
    end
  rescue Designs::Approval::TurnActive
    back(alert: "Wait for the current turn to finish, then update from master.")
  rescue Designs::Repo::Busy
    back(alert: BUSY)
  rescue StandardError => e
    report(e, "updating from master")
    back(alert: "The update from master did not go through — try again in a minute.")
  end

  # Hands the idea over to Details, with Claude writing its description from
  # the designs. An idea already past Details stays where it is.
  def continue_to_details
    @idea.update!(workshop_stage: "details") if @idea.workshop_stage.in?(%w[new briefing])
    Designs::DescribeJob.perform_later(@idea.id)
    flash[:clar_toast] = "Writing the description from the designs…"
    redirect_to workshop_idea_path(@idea, stage: "details"), status: :see_other
  end

  def describe
    Designs::DescribeJob.perform_later(@idea.id)
    back(toast: "Updating the description from the designs…")
  end

  # Sends the latest approval's Jira links again.
  def sync_links
    approval = @idea.design_approvals.order(:number).last
    Designs::SyncJiraLinksJob.perform_later(approval.id) if approval
    back(toast: "Sending the Jira links again…")
  end

  # Ruling P2-R7: the chat's latest turn, once it has failed, whether or not
  # the chat holds its error (a turn failed as cut off has none).
  def retry
    session = ChatSession.find_active_for(@idea, purpose: "designs")
    turn = session&.design_turns&.order(:id)&.last
    if turn&.failed?
      turn.update!(status: "queued", error: nil, finished_at: nil)
      Designs::TurnJob.perform_later(turn.id)
    end
    load_chat
    render_chat
  end

  private

  def set_idea
    @idea = current_workshop_project.tasks.pipeline.find(params[:idea_id])
  end

  def require_designs!
    redirect_to workshop_idea_path(@idea), alert: NOT_SET_UP unless current_workshop_project.designs_ready?
  end

  def project
    current_workshop_project
  end

  def repo
    @repo ||= Designs::Repo.new(project)
  end

  def slug
    Designs::BranchNames.slug(@idea)
  end

  def wip
    Designs::BranchNames.wip(@idea)
  end

  def start_turn(content)
    session = ChatSession.designs_for!(@idea, user: current_user, codebase_path: repo.worktree_path(wip).to_s)
    turn = DesignTurn.transaction do
      request = session.chat_messages.create!(role: "user", user: current_user, content: content)
      DesignTurn.create!(chat_session: session, chat_message: request)
    end
    Designs::TurnJob.perform_later(turn.id)
  end

  def load_chat
    session = ChatSession.find_active_for(@idea, purpose: "designs")
    turns = session ? session.design_turns : DesignTurn.none
    @messages = session ? session.chat_messages.ordered.to_a : []
    @active = turns.active.exists?
    @last_commit = turns.where(status: "succeeded").where.not(commit_sha: nil).order(:id).last&.commit_sha
    latest = turns.order(:id).last
    @failed_turn = latest if latest&.failed?
    @no_key = ProjectCredentials.new(project).designs_api_key.nil?
  end

  # The contexts and the entry page come from the task's worktree, or from
  # the clone before its first turn. The preview shows the task's published
  # work, else master.
  def load_screen
    @slug = slug
    tree = repo.worktree_path(wip)
    branch = Designs::WorkingBranch.new(tree.exist? ? tree : repo.root, @slug)
    @dimensions = branch.dimensions
    @ctx = chosen_ctx
    publisher = Designs::Publisher.new(project, nil)
    slot = publisher.published?(wip) ? wip : Designs::Repo::MASTER
    @preview_base = publisher.url(slot, branch.entry_path)
    @preview_url = publisher.url(slot, branch.entry_path, ctx: @ctx)
    @wip_head = wip_head
    @waiting = waiting
    @can_approve = !@active && @waiting != 0
    described = @idea.designs_described_sha
    @description_stale = described.present? && @wip_head.present? && described != @wip_head
    @offer_update = flash[:designs_update].present?
    @approval = @idea.design_approvals.order(:number).last
  end

  # Ruling P2-R27: the value of each dimension the page's ?ctx= names, when it
  # is one of that dimension's, else its default. Dimensions are matched by
  # position, as the picker writes them: their ids are Claude's and may repeat.
  def chosen_ctx
    asked = params[:ctx].to_s.split(",")
    @dimensions.each_with_index.map do |dimension, index|
      ids = dimension["values"].map { |value| value["id"] }
      ids.include?(asked[index]) ? asked[index] : dimension["default"]
    end
  end

  # Commits on the working branch that the approved design, or master before
  # the first approval, lacks: 0 before the first turn. Ruling P2-R26: read
  # without the repo's lock, and nil when git cannot say, which shows no count
  # and leaves Approve to say whether there is anything.
  # The working branch's head, read without the lock; nil before the first
  # turn, and nil with @git_unreadable set when git cannot answer.
  def wip_head
    repo.head(wip, lock: false)
  rescue StandardError => e
    report(e, "reading the working branch")
    @git_unreadable = true
    nil
  end

  def waiting
    return if @git_unreadable
    return 0 unless @wip_head

    design = Designs::BranchNames.design(@idea)
    base = repo.head(design, lock: false) ? design : Designs::Repo::MASTER
    repo.commits_ahead(wip, base: base, lock: false)
  rescue StandardError => e
    report(e, "counting the commits waiting for approval")
    nil
  end

  def render_chat(status: :ok)
    render partial: "workshop/designs/chat", status: status
  end

  # Back to the screen as it was, contexts and all: the picker keeps them in
  # the page's address.
  def back(toast: nil, alert: nil)
    flash[:clar_toast] = toast if toast
    flash[:alert] = alert if alert
    redirect_back_or_to workshop_idea_designs_path(@idea), status: :see_other
  end

  def report(error, doing)
    Rails.logger.error("[#{self.class.name}] #{slug}: #{doing}: #{error.class}: #{error.message}")
  end
end
