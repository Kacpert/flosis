class Workshop::IdeasController < Workshop::BaseController
  # Actions land in Phase 3 (create/show) and Phase 4 (update). The routes are
  # defined now because the pipeline rows/cards reference their path helpers;
  # the controller class exists (empty) so Rails can load it once a request
  # actually dispatches here, without requiring the finished behavior yet.

  def show
  end

  def create
  end

  def update
  end
end
