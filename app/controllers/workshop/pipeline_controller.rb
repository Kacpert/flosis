class Workshop::PipelineController < Workshop::BaseController
  def index
    # NEVER redirect to workshop_path here — WorkshopController#index redirects
    # back to the pipeline (Step 5), which would loop. Render an empty state.
    return render :no_project unless current_workshop_project

    load_pipeline # shared with IdeasController#create's error re-render (BaseController)
  end
end
