# What the person does with one feature on an import's page (Designs imports):
# Retry it (with words for the AI first, if they like), answer the AI's
# question (Send and continue), or set it aside (Not needed). Each queues the
# work and starts it; the import's job builds what is queued one at a time.
# A re-import's features are fixed on its thread instead.
class Workshop::DesignImportFeaturesController < Workshop::BaseController
  before_action { require_permission!(:designs) }
  before_action { require_permission!(:configuration) }
  include DesignsVisibility
  before_action :load_feature

  def retry
    if @feature.problem || @feature.status == "set_aside"
      @feature.queue!(reply: params[:words])
      @import.start_work!
      flash[:clar_toast] = "Retrying #{@feature.name}"
    end
    back
  end

  def reply
    text = params[:reply].to_s.strip
    if @feature.problem == :waiting && text.present?
      @feature.queue!(reply: text, fresh: false)
      @import.start_work!
      flash[:clar_toast] = "Sent · #{@feature.name} goes on"
    end
    back
  end

  def set_aside
    @feature.update!(status: "set_aside", resets_at: nil) if @feature.problem
    back
  end

  private

  def load_feature
    @import = current_workshop_project.design_setups.where.not(kind: "reimport").find(params[:design_import_id])
    @feature = @import.features.find(params[:id])
  end

  def back
    redirect_to helpers.import_page_path(@import)
  end
end
