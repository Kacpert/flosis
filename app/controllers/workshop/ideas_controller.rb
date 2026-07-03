class Workshop::IdeasController < Workshop::BaseController
  # show/update land in Phase 4. head :not_implemented guards against a stray
  # request raising MissingTemplate before those actions are filled in.

  def show
    head :not_implemented
  end

  def create
    if params[:task_id].present?
      import_from_jira
    else
      create_new_idea
    end
  end

  def update
    head :not_implemented
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
end
