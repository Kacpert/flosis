class WorkshopController < ApplicationController
  include WorkspaceScoped

  layout "workshop"

  before_action { require_product!(:workshop) }
  before_action :require_admin!
  before_action :require_workshop!

  def index
    redirect_to workshop_pipeline_path
  end

  # Legacy screen retired (Task 10.1) — the new-idea MODAL on the pipeline
  # replaces it.
  def new_idea
    redirect_to workshop_pipeline_path
  end

  # Legacy screen retired (Task 10.1) — the pipeline's modals replace the old
  # create-task flow.
  def start
    redirect_to workshop_pipeline_path
  end

  # Legacy screen retired (Task 10.1). Old bookmarked/linked brief URLs land on
  # the new workspace at the briefing stage. A task that never entered the
  # pipeline (e.g. a plain Jira task that was briefed pre-redesign but never
  # opened in Clar) has no workshop/ideas#show to land on — fall back to the
  # pipeline rather than 404.
  def brief
    @task = Task.where(project: current_workspace.projects).find(params[:id])

    if @task.in_pipeline?
      redirect_to workshop_idea_path(@task, stage: "briefing")
    else
      redirect_to workshop_pipeline_path
    end
  end

  private

  def require_workshop!
    redirect_to root_path unless current_workspace&.workshop_enabled?
  end
end
