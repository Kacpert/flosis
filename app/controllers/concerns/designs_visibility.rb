# Workshop Designs v2: until Flosis staff switch Designs on for a project,
# only they see it — its module, its threads and its setup alike.
module DesignsVisibility
  extend ActiveSupport::Concern

  included do
    before_action :require_designs_visible!
  end

  private

  def require_designs_visible!
    project = current_workshop_project
    raise ActionController::RoutingError, "Not Found" unless project && (project.designs_enabled? || current_user.flosis_staff?)
  end
end
