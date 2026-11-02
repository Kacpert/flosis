class Workshop::BaseController < ApplicationController
  include WorkspaceScoped

  layout "workshop"

  before_action { require_product!(:workshop) }
  before_action :require_workshop!
  before_action :require_project_member!
  before_action :require_current_project!
  before_action :set_pipeline_badge
  before_action :announce_designs_ready

  private

  # Everything in the Workshop happens inside a project. A workspace with none
  # yet (a new organization) is sent to the pipeline's empty state, which is
  # where its administrator creates the first; the pages that manage without a
  # project skip this.
  def require_current_project!
    redirect_to workshop_pipeline_path unless current_workshop_project
  end

  def require_workshop!
    redirect_to root_path unless current_workspace&.workshop_enabled?
  end

  # Workshop Designs v2: whoever started a project's Designs setup is told
  # once, on their next page, that master is ready.
  def announce_designs_ready
    project = current_workshop_project or return
    setup = project.design_setups.where(status: "approved", design_thread_id: nil, notified_at: nil, started_by: current_user)
                   .where.not(finished_at: nil).order(:id).last
    return unless setup

    setup.update_column(:notified_at, Time.current)
    flash.now[:clar_toast] = "Designs ready · #{project.name} @ master"
  end

  def set_pipeline_badge
    @pipeline_badge_count = current_workshop_project ? current_workshop_project.tasks.pipeline_active.count : 0
  end

  # Loads the Create Tasks pipeline list (@ideas) plus stage/source counts.
  # Shared by PipelineController#index and IdeasController#create's error
  # re-render, so an invalid new-idea submission can render the pipeline page
  # (with the modal errors) instead of a semantically-odd redirect-with-422.
  STAGE_ORDER_SQL = "CASE workshop_stage WHEN 'new' THEN 0 WHEN 'briefing' THEN 1 " \
                    "WHEN 'details' THEN 2 ELSE 3 END".freeze

  def load_pipeline
    scope = current_workshop_project.tasks.pipeline.includes(:design_request, :design_thread)
    scope = scope.where(workshop_stage: params[:stage]) if Task::WORKSHOP_STAGES.include?(params[:stage])
    scope = case params[:source]
            when "jira"  then scope.jira_synced
            when "local" then scope.local_only
            else scope
            end
    if params[:q].present?
      # LOWER(...) LIKE, not ILIKE — must run on MySQL in production
      q = "%#{ActiveRecord::Base.sanitize_sql_like(params[:q].downcase)}%"
      scope = scope.left_joins(:pipeline_author).where(
        "LOWER(tasks.name) LIKE :q OR LOWER(tasks.external_reference) LIKE :q OR LOWER(users.name) LIKE :q", q: q
      )
    end
    @ideas = case params[:sort]
             when "oldest" then scope.reorder(pipeline_entered_at: :asc)
             when "stage"  then scope.reorder(Arel.sql(STAGE_ORDER_SQL))
             when "title"  then scope.reorder(:name)
             else scope
             end
    # .pipeline carries an ORDER BY (pipeline_entered_at desc); Postgres requires
    # any ordered column to also be in the GROUP BY, so drop the order before
    # aggregating (count is unaffected by row order either way).
    @counts = current_workshop_project.tasks.pipeline.reorder(nil).group(:workshop_stage).count
    @source_counts = { all: current_workshop_project.tasks.pipeline.count,
                       jira: current_workshop_project.tasks.pipeline.jira_synced.count,
                       local: current_workshop_project.tasks.pipeline.local_only.count }
  end
end
