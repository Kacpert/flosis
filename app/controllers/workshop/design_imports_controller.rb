# What the person does with imports (Designs imports): New import, a resync
# from the app since the last one; and on an import's page, Retry all the features that could not finish or were not started (the
# features the AI asked something about wait for their answer instead), and
# Missing feature? · Add, which puts a feature the map missed on the import,
# from the person's description, for the AI to find and build like any other.
class Workshop::DesignImportsController < Workshop::BaseController
  before_action { require_permission!(:designs) }
  before_action { require_permission!(:configuration) }
  include DesignsVisibility
  before_action :load_import, except: :create

  # New import: a resync from the last import that is over, once master has
  # the first one and while no import runs.
  def create
    project = current_workshop_project
    since = helpers.import_resync_from(project)
    if since.nil?
      flash[:clar_toast] = "A new import starts once the first one is on master."
      return redirect_to workshop_designs_overview_path(tab: "imports")
    end
    if project.design_setups.working.exists?
      flash[:clar_toast] = "An import is already running. It goes on from where it is."
      return redirect_to workshop_designs_overview_path(tab: "imports")
    end

    resync = project.design_setups.create!(kind: "resync", since_setup: since, status: "active", phase: "resync", step: 0, started_by: current_user)
    resync.start_work!
    flash[:clar_toast] = "Looking for what changed in the app since #{resync.since_label}"
    redirect_to helpers.import_page_path(resync)
  end

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
