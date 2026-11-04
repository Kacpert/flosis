# What the person does with a whole import on its page (Designs imports):
# Retry all the features that could not finish or were not started. The
# features the AI asked something about wait for their answer instead.
class Workshop::DesignImportsController < Workshop::BaseController
  before_action { require_permission!(:designs) }
  before_action { require_permission!(:configuration) }
  include DesignsVisibility
  before_action :load_import

  def retry_all
    features = @import.needs_you.select(&:retryable?)
    features.each(&:queue!)
    if features.any?
      @import.start_work!
      flash[:clar_toast] = "Retrying #{features.size} #{features.size == 1 ? 'feature' : 'features'}"
    end
    redirect_to helpers.import_page_path(@import)
  end

  private

  def load_import
    @import = current_workshop_project.design_setups.where.not(kind: "reimport").find(params[:id])
  end
end
