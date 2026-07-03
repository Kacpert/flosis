class Workshop::BaseController < ApplicationController
  include WorkspaceScoped

  layout "workshop"

  before_action { require_product!(:workshop) }
  before_action :require_workshop!
  before_action :set_pipeline_badge

  private

  def require_workshop!
    redirect_to root_path unless current_workspace&.workshop_enabled?
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
    scope = current_workshop_project.tasks.pipeline.includes(:design_request)
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
