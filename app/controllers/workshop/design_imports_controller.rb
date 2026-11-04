# What the person does with a whole import on its page (Designs imports):
# Retry all the features that could not finish or were not started (the
# features the AI asked something about wait for their answer instead), and
# Missing feature? · Add, which puts a feature the map missed on the import,
# from the person's description, for the AI to find and build like any other.
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

  def add_feature
    description = params[:description].to_s.strip
    if description.present? && @import.done?
      contexts = Array(params[:contexts]).map(&:to_s) & current_workshop_project.design_setup_roles.map { |role| Designs::SignIn.slug(role) }
      feature = @import.features.create!(name: feature_name(description), key: DesignSetupFeature.key_for(feature_name(description), @import.features.pluck(:key)),
                                         position: @import.features.maximum(:position).to_i + 1, source: "added", status: "todo",
                                         queued_at: Time.current, contexts: contexts, brief: description)
      @import.start_work!
      flash[:clar_toast] = "Looking for #{feature.name}"
    end
    redirect_to helpers.import_page_path(@import)
  end

  private

  # The description's first sentence, as the map would name a feature.
  def feature_name(description)
    description.squish.split(/(?<=[.!?])\s/).first.to_s.truncate(120)
  end

  def load_import
    @import = current_workshop_project.design_setups.where.not(kind: "reimport").find(params[:id])
  end
end
