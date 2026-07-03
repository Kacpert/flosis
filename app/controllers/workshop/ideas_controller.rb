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

  # Stamps the brief as saved-locally without pushing to Jira. Stage stays
  # at briefing either way — this is a "keep it here for now" action.
  def save_locally
    @idea = current_workshop_project.tasks.pipeline.find(params[:id])
    @idea.update!(brief_saved_locally_at: Time.current)

    flash[:clar_toast] = "Brief saved to the task locally · not pushed"
    redirect_to workshop_idea_path(@idea, stage: "briefing")
  end

  # Commits the current brief to Jira (creating the issue for a local idea,
  # or updating the description for a Jira-linked one) and sets AI actions =
  # Briefed — see JiraWriter#commit_brief. Only advances the idea to the
  # "details" stage when the Jira write actually succeeds; a failure leaves
  # the idea in briefing and surfaces the error instead of silently
  # "succeeding".
  def push_jira
    @idea = current_workshop_project.tasks.pipeline.find(params[:id])
    result = JiraWriter.new(workspace: current_workspace).commit_brief(@idea.current_brief)

    if result[:ok]
      @idea.current_brief.mark_briefed!
      @idea.update!(brief_saved_locally_at: nil, workshop_stage: "details")
      flash[:clar_toast] = "Pushed to Jira · AI actions = Briefed"
      redirect_to workshop_idea_path(@idea, stage: "details")
    else
      redirect_to workshop_idea_path(@idea, stage: "briefing"), alert: "Couldn't write to Jira: #{result[:error]}"
    end
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
