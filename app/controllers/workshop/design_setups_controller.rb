# The current project's setup run, for Flosis staff: Flosis crawls the running
# app as each role, then Claude recreates it on wip/setup in three phases
# (design system, components, designs) that staff review in the chat, and the
# run is approved into master. The screen is the Designs screen's chat and
# preview, with its own top bar. Turns run on Flosis's own key.
class Workshop::DesignSetupsController < Workshop::BaseController
  include FlosisStaffOnly

  BUSY = Workshop::DesignsController::BUSY

  def show
    DesignTurn.fail_stale!
    return redirect_to(inputs_path, alert: "Start a setup run first.") unless setup

    load_chat
    load_screen
  end

  def chat
    DesignTurn.fail_stale!
    load_chat
    render_chat
  end

  # A project has one active run: starting again opens it.
  def start
    return redirect_to(inputs_path, alert: Designs::Subject::SetupSubject::NO_KEY) unless setup_key?

    unless setup
      run = project.design_setups.create!(started_by: current_user)
      setup_chat!
      request_crawl(run) if project.design_app_url.present? && project.design_setup_roles.any?
    end
    redirect_to workshop_design_setup_path
  end

  def message
    load_chat
    return render_chat(status: :unprocessable_entity) if @no_key || setup.nil?

    content = params[:content].to_s.strip
    if content.present?
      turn = DesignTurn.transaction do
        request = setup_chat!.chat_messages.create!(role: "user", user: current_user, content: content)
        DesignTurn.create!(chat_session: setup_chat!, chat_message: request)
      end
      Designs::TurnJob.perform_later(turn.id)
    end
    load_chat
    render_chat
  end

  def next_phase
    phase = setup&.next_phase!
    if phase
      setup_chat!.chat_messages.create!(role: "assistant", kind: "system", content: "Phase: #{phase.humanize}.")
      flash[:clar_toast] = "Phase: #{phase.humanize}"
    end
    redirect_to workshop_design_setup_path, status: :see_other
  end

  def approve
    number = Designs::Approval.for_setup(project, user: current_user, wait: false).approve!
    flash[:clar_toast] = "Setup approved as version #{number}."
    redirect_to inputs_path, status: :see_other
  rescue Designs::Approval::NothingToApprove
    back(alert: "Nothing new to approve.")
  rescue Designs::Repo::Conflict
    back(alert: "Master has changed in the same files since the run began — ask in the chat to bring wip/setup up to date, then approve again.")
  rescue Designs::Approval::TurnActive
    back(alert: "Wait for the current turn to finish, then approve.")
  rescue Designs::Repo::Busy
    back(alert: BUSY)
  rescue StandardError => e
    Rails.logger.error("[#{self.class.name}] project #{project.id}: approving: #{e.class}: #{e.message}")
    back(alert: "The approval did not go through — try again in a minute.")
  end

  # Ruling P2-R7, as on a task's screen.
  def retry
    turn = setup_chat&.design_turns&.order(:id)&.last
    if turn&.failed?
      turn.update!(status: "queued", error: nil, finished_at: nil)
      Designs::TurnJob.perform_later(turn.id)
    end
    load_chat
    render_chat
  end

  private

  def project
    current_workshop_project
  end

  def setup
    @setup ||= project.design_setups.active.order(:id).last
  end

  # Not "session": that is the controller's own, which the workspace is read from.
  def setup_chat
    ChatSession.active.where(project: project, purpose: "designs_setup").order(created_at: :desc).first
  end

  def setup_chat!
    @setup_chat ||= ChatSession.designs_setup_for!(project, user: current_user, codebase_path: repo.worktree_path(wip).to_s)
  end

  def repo
    @repo ||= Designs::Repo.new(project)
  end

  def wip
    Designs::BranchNames::SETUP
  end

  def setup_key?
    ENV["FLOSIS_DESIGNS_SETUP_API_KEY"].present?
  end

  def inputs_path
    workshop_configuration_path(tab: "designs")
  end

  def request_crawl(run)
    run.update!(crawl_requested_at: Time.current, crawled_at: nil, crawl_error: nil)
    Designs::CrawlJob.perform_later(run.id)
  end

  def load_chat
    current = setup_chat
    turns = current ? current.design_turns : DesignTurn.none
    @messages = current ? current.chat_messages.ordered.to_a : []
    @active = turns.active.exists?
    @last_commit = turns.where(status: "succeeded").where.not(commit_sha: nil).order(:id).last&.commit_sha
    latest = turns.order(:id).last
    @failed_turn = latest if latest&.failed?
    @no_key = Designs::Subject::SetupSubject::NO_KEY unless setup_key?
    @designs_urls = { chat: chat_workshop_design_setup_path, message: message_workshop_design_setup_path,
                      retry: retry_workshop_design_setup_path }
  end

  # As on a task's screen: contexts and the entry page from the worktree, or
  # from the clone before the first turn; the preview shows wip/setup once
  # published, else master; refs read without the repo's lock (P2-R26).
  def load_screen
    tree = repo.worktree_path(wip)
    branch = Designs::WorkingBranch.new(tree.exist? ? tree : repo.root, "setup")
    @dimensions = branch.dimensions
    @ctx = @dimensions.each_with_index.map do |dimension, index|
      asked = params[:ctx].to_s.split(",")[index]
      dimension["values"].any? { |value| value["id"] == asked } ? asked : dimension["default"]
    end
    publisher = Designs::Publisher.new(project, nil)
    slot = publisher.published?(wip) ? wip : Designs::Repo::MASTER
    @preview_base = publisher.grant_url(slot, branch.entry_path)
    @preview_url = publisher.grant_url(slot, branch.entry_path, ctx: @ctx)
    @phase_number = DesignSetup::PHASES.index(setup.phase) + 1
    @waiting = waiting
    @last_phase = setup.phase == DesignSetup::PHASES.last
    @can_approve = @last_phase && !@active && @waiting != 0
    @crawl_status = crawl_status
  end

  def waiting
    return 0 unless repo.head(wip, lock: false)

    repo.commits_ahead(wip, lock: false)
  rescue StandardError => e
    Rails.logger.warn("[#{self.class.name}] project #{project.id}: counting the commits waiting: #{e.class}: #{e.message}")
    nil
  end

  def crawl_status
    if setup.crawling? then "Crawling…"
    elsif setup.crawl_error.present? then "Crawl failed: #{setup.crawl_error}"
    elsif setup.crawled_at then "Crawled #{crawled_pages} pages"
    end
  end

  def crawled_pages
    summary = JSON.parse(File.read(File.join(setup.crawl_dir.to_s, "crawl.json")))
    Array(summary["roles"]).grep(Hash).sum { |role| Array(role["pages"]).size }
  rescue JSON::ParserError, SystemCallError, TypeError
    "the"
  end

  def render_chat(status: :ok)
    render partial: "workshop/designs/chat", status: status
  end

  def back(alert:)
    flash[:alert] = alert
    redirect_back_or_to workshop_design_setup_path, status: :see_other
  end
end
