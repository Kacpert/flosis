class Workshop::PipelineController < Workshop::BaseController
  STAGE_ORDER_SQL = "CASE workshop_stage WHEN 'new' THEN 0 WHEN 'briefing' THEN 1 " \
                    "WHEN 'details' THEN 2 ELSE 3 END".freeze

  def index
    # NEVER redirect to workshop_path here — WorkshopController#index redirects
    # back to the pipeline (Step 5), which would loop. Render an empty state.
    return render :no_project unless current_workshop_project

    scope = current_workshop_project.tasks.pipeline
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
