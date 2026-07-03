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
end
