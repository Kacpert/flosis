class Workshop::IdeasController < Workshop::BaseController
  # Server-side whitelist of legal stepper transitions. Anything else (e.g.
  # skipping a stage, or moving backwards) is rejected with 422 — the stepper
  # UI only ever links to done/current steps, but the endpoint still guards
  # itself against a forged/stray request.
  LEGAL_TRANSITIONS = {
    "new"      => "briefing",
    "briefing" => "details",
    "details"  => "ready",
  }.freeze

  def show
    @idea = current_workshop_project.tasks.pipeline.find(params[:id])
    @stage = params[:stage].presence_in(%w[briefing details ready]) ||
             (@idea.stage_new? ? "briefing" : @idea.workshop_stage)

    seed_v0_detail_draft if @stage == "details"
    load_ready_summary if @stage == "ready"

    render "workshop/ideas/show"
  end

  def create
    if params[:task_id].present?
      import_from_jira
    else
      create_new_idea
    end
  end

  # Rename: local tasks rename freely; Jira-linked tasks rename the local
  # mirror only (the `name` column) — never pushed back to Jira from here.
  # The header pencil (clar_rename_controller.js) issues a fetch PATCH and
  # applies the new name optimistically, so a plain 200 is enough — no body
  # required, but we return the persisted name for the JS to reconcile with.
  def update
    @idea = current_workshop_project.tasks.pipeline.find(params[:id])

    if @idea.update(rename_params)
      # The toast is dispatched client-side by clar_rename_controller on success;
      # a server flash never surfaces on this JSON response.
      render json: { name: @idea.name }
    else
      render json: { errors: @idea.errors.full_messages }, status: :unprocessable_entity
    end
  end

  def advance
    @idea = current_workshop_project.tasks.pipeline.find(params[:id])
    to = params[:to].to_s

    if LEGAL_TRANSITIONS[@idea.workshop_stage] == to
      @idea.update!(workshop_stage: to)
      redirect_to workshop_idea_path(@idea, stage: to)
    else
      head :unprocessable_entity
    end
  end

  # Stamps the current stage's content as saved-locally without pushing to
  # Jira. Briefing: stamps brief_saved_locally_at, stays at briefing (a "keep
  # it here for now" action). Details: stamps detail_saved_locally_at and
  # ADVANCES to "ready" — details is the last stage with AI involvement, so
  # "save locally" here means "finished, without Jira".
  def save_locally
    @idea = current_workshop_project.tasks.pipeline.find(params[:id])

    if @idea.workshop_stage == "details"
      @idea.update!(detail_saved_locally_at: Time.current, workshop_stage: "ready")
      flash[:clar_toast] = "Saved to the task locally · finished without Jira"
      redirect_to workshop_idea_path(@idea, stage: "ready")
    else
      @idea.update!(brief_saved_locally_at: Time.current)
      flash[:clar_toast] = "Brief saved to the task locally · not pushed"
      redirect_to workshop_idea_path(@idea, stage: "briefing")
    end
  end

  # Commits the current stage's content to Jira. Briefing: commits the current
  # brief (creating the issue for a local idea, or updating the description
  # for a Jira-linked one) and sets AI actions = Briefed — see
  # JiraWriter#commit_brief. Details: commits the current AI draft's
  # description and sets AI actions = Detailed — see JiraWriter#commit_detail
  # (local ideas without a Jira key cannot push details; the primary button is
  # disabled in that case, see _document_panel.html.erb). Either way, only
  # advances the stage when the Jira write actually succeeds; a failure keeps
  # the idea on its current stage and surfaces the error instead of silently
  # "succeeding".
  def push_jira
    @idea = current_workshop_project.tasks.pipeline.find(params[:id])

    case @idea.workshop_stage
    when "details"
      result = JiraWriter.new(workspace: current_workspace).commit_detail(@idea.current_detail_draft)

      if result[:ok]
        @idea.update!(detail_saved_locally_at: nil, workshop_stage: "ready")
        flash[:clar_toast] = "Description sent to Jira · marked Detailed"
        redirect_to workshop_idea_path(@idea, stage: "ready")
      else
        redirect_to workshop_idea_path(@idea, stage: "details"), alert: "Couldn't write to Jira: #{result[:error]}"
      end
    when "ready"
      # A local idea that finished via "Save locally" reaches Ready with no Jira
      # issue. Pushing from the Ready screen creates the issue and MUST keep the
      # idea at "ready" — it's already done; pushing must not regress the stage.
      # Prefer the details draft (the richer, implementation-ready description); a
      # task that skipped details straight from briefing pushes the brief instead.
      writer = JiraWriter.new(workspace: current_workspace)
      detail = @idea.current_detail_draft
      result = detail.present? ? writer.commit_detail(detail) : writer.commit_brief(@idea.current_brief)

      if result[:ok]
        @idea.current_brief&.mark_briefed!
        @idea.update!(brief_saved_locally_at: nil, detail_saved_locally_at: nil)
        flash[:clar_toast] = "Pushed to Jira"
        redirect_to workshop_idea_path(@idea, stage: "ready")
      else
        redirect_to workshop_idea_path(@idea, stage: "ready"), alert: "Couldn't write to Jira: #{result[:error]}"
      end
    else
      # Briefing → Details does NOT push to Jira (the Jira write happens on the
      # Details step). "Brief & mark Briefed" just marks the brief briefed locally
      # and advances the stage. If there's no brief yet, stay put and warn.
      if @idea.current_brief.blank?
        redirect_to workshop_idea_path(@idea, stage: "briefing"), alert: "Draft a brief first."
      else
        @idea.current_brief.mark_briefed!
        @idea.update!(workshop_stage: "details")
        flash[:clar_toast] = "Briefed · moved to Details"
        redirect_to workshop_idea_path(@idea, stage: "details")
      end
    end
  end

  # Manual trigger for the AI auto-estimation engine (workspace.estimation_trigger
  # == "manual" is the button-only path, but this endpoint itself works
  # regardless of the configured trigger — a human explicitly asked for it).
  def estimate
    @idea = current_workshop_project.tasks.find(params[:id])
    AutoEstimateJob.perform_later(@idea.id)
    flash[:clar_toast] = "Estimating…"
    redirect_to workshop_idea_path(@idea)
  end

  private

  def create_new_idea
    task = current_workshop_project.tasks.new(name: idea_params[:title], description: idea_params[:description])

    if task.save
      task.enter_pipeline!(author: current_user, stage: "briefing")

      if idea_params[:description].present?
        task.briefs.create!(workspace: task.project.workspace, version: 0,
                            origin: "user", status: "draft", content: idea_params[:description]).make_current!
      end

      flash[:clar_toast] = %(Idea saved · "#{idea_params[:title]}")
      redirect_to workshop_idea_path(task)
    else
      flash.now[:alert] = task.errors.full_messages.to_sentence
      load_pipeline
      render "workshop/pipeline/index", status: :unprocessable_entity
    end
  end

  # Pulls an existing Jira-synced task (browsed via the Jira board modal)
  # into the pipeline. Seeds a v0 user brief from its current description,
  # same as the new-idea path, so Briefing always starts from something.
  def import_from_jira
    task = current_workshop_project.tasks.find(params[:task_id])
    task.enter_pipeline!(author: current_user, stage: "briefing")

    if task.description.present?
      task.briefs.create!(workspace: task.project.workspace, version: 0,
                          origin: "user", status: "draft", content: task.description).make_current!
    end

    flash[:clar_toast] = "Imported #{task.external_reference} from Jira"
    redirect_to workshop_idea_path(task)
  end

  # On first entering the details stage, seed a v0 "user description" AI
  # draft from the task's current description so the details document panel
  # always shows something to refine from, same as briefing's v0 brief.
  # Explicit version: 0 survives TaskDraft's `before_create { self.version ||= ... }`.
  def seed_v0_detail_draft
    return if @idea.task_drafts.by_source(TaskDraft::REFINE_SOURCE).exists?
    return if @idea.description.blank?

    @idea.task_drafts.create!(source: TaskDraft::REFINE_SOURCE, origin: "user", version: 0,
                              content: @idea.description).make_current!
  end

  # Summary data for the Ready screen (Task 5.4). "Pushed" (detail committed
  # to Jira) is the signal for both the IN JIRA/LOCAL badge and whether the
  # Push to Jira button still makes sense — see JiraWriter#commit_detail,
  # which stamps the current detail draft's pushed_at on success.
  def load_ready_summary
    @detail_pushed = @idea.current_detail_draft&.pushed_at.present?
    @ai_actions = if @detail_pushed
      "Detailed"
    elsif @idea.current_brief&.briefed?
      "Briefed"
    else
      "—"
    end
    @ai_estimate_points = @idea.latest_breakdown_total_points
    @versions_saved = @idea.briefs.count + @idea.task_drafts.by_source("ai").count
    @show_push_to_jira = !@detail_pushed && !@idea.current_brief&.briefed?
  end

  def idea_params
    params.require(:idea).permit(:title, :description)
  end

  # Rename only ever touches the local `name` column — for Jira-linked tasks
  # this deliberately does NOT sync back to Jira (the header shows a "local
  # only" hint for those; see _workspace_header.html.erb).
  def rename_params
    params.require(:idea).permit(:name)
  end
end
