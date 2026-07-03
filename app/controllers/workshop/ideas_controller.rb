class Workshop::IdeasController < Workshop::BaseController
  include ClarHelper # for clar_toast

  # show/update land in Phase 4. head :not_implemented guards against a stray
  # request raising MissingTemplate before those actions are filled in.

  def show
    head :not_implemented
  end

  def create
    task = current_workshop_project.tasks.new(name: idea_params[:title], description: idea_params[:description])

    if task.save
      task.enter_pipeline!(author: current_user, stage: "briefing")

      if idea_params[:description].present?
        task.briefs.create!(workspace: task.project.workspace, version: 0,
                            origin: "user", status: "draft", content: idea_params[:description]).make_current!
      end

      clar_toast(%(Idea saved · "#{idea_params[:title]}"))
      redirect_to workshop_idea_path(task)
    else
      clar_toast(task.errors.full_messages.to_sentence)
      redirect_to workshop_pipeline_path, status: :unprocessable_entity
    end
  end

  def update
    head :not_implemented
  end

  private

  def idea_params
    params.require(:idea).permit(:title, :description)
  end
end
