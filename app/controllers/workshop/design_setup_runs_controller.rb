# Setting Designs up for the Workshop's current project (Workshop Designs v2,
# after Kacper's ClearBacklog-3.html): the form (technology, repositories,
# staging and contexts), "Build designs", which runs the import in the
# background (Designs::SetupRunJob), its progress page, and "Edit setup" /
# "Re-import", which run it again on a thread of its own.
#
# This version builds HTML + CSS with Tailwind or plain CSS: the other
# frameworks and UI systems are shown, as designed, but cannot be picked yet.
class Workshop::DesignSetupRunsController < Workshop::BaseController
  before_action { require_permission!(:designs) }
  before_action(except: :show) { require_permission!(:configuration) }
  include DesignsVisibility
  # A run lasts hours: another one on the same branch would undo it.
  before_action :refuse_while_running, only: %i[create update reimport]
  before_action :refuse_designs_when_ai_paused, only: %i[create update retry reimport]

  FRAMEWORKS = [ [ "vue", "Vue.js", "3.4" ], [ "react", "React", "18.3" ], [ "angular", "Angular", "17" ], [ "html", "HTML + CSS", nil ] ].freeze
  UI_SYSTEMS = [ [ "foundation", "Foundation", "6.8" ], [ "bootstrap", "Bootstrap", "5.3" ], [ "tailwind", "Tailwind", "4" ],
                 [ "material", "Material", "3" ], [ "custom", "Custom", nil ] ].freeze
  # The form's rules live in Designs::SetupForm, which New import shares.
  SUPPORTED = Designs::SetupForm::SUPPORTED
  INCOMPLETE = Designs::SetupForm::INCOMPLETE

  def new
    @project = current_workshop_project
    @editing = false
  end

  def edit
    @project = current_workshop_project
    @editing = true
    render :new
  end

  def create
    @project = current_workshop_project
    return incomplete unless save_form

    setup = @project.design_setups.create!(status: "active", phase: "map", step: 0, started_by: current_user)
    Designs::SetupRunJob.perform_later(setup.id)
    flash[:clar_toast] = "Building designs in the background · several hours"
    redirect_to workshop_design_setup_run_path
  end

  def update
    @project = current_workshop_project
    @editing = true
    return incomplete unless save_form

    reimport
  end

  def show
    @project = current_workshop_project
    @setup = @project.design_setups.first_imports.order(:id).last
    return redirect_to(workshop_designs_overview_path) if @setup.nil?
    # Once master has it, the import's page is in Designs (Designs imports).
    return redirect_to(workshop_designs_overview_path(tab: "imports", import: @setup.id)) if @setup.done?

    @features = @setup.features.to_a
    @up_next = @features.find { |feature| feature.status == "todo" }
    @progress = Designs::RunProgress.screens(@setup, @features.find(&:running?))
    roles = @project.design_setup_roles.to_a
    @names = roles.to_h { |role| [ Designs::SignIn.slug(role), role.name ] }
    @where = where_line(roles)
  end

  # The import shown (else the latest): a stopped run goes on from its step;
  # an import already on master that an older bug marked failed is put back,
  # and what is queued on it goes on. A re-import whose thread was deleted
  # stays as it is.
  def retry
    project = current_workshop_project
    setup = params[:import].present? ? project.design_setups.find_by(id: params[:import]) : project.design_setups.order(:id).last
    return redirect_to(helpers.import_page_path(setup), alert: DesignSetup::THREAD_DELETED) if setup&.thread_deleted?

    if setup&.stopped? && setup.unit_live?
      flash[:clar_toast] = "The import is still stopping. Try again in a minute."
      return redirect_to(helpers.import_page_path(setup))
    end

    if setup&.failed? && setup.finished_at.nil?
      resume_stopped!(setup) if setup.stopped?
      setup.update!(status: "active", error: nil, unit_job_id: nil, unit_deadline_at: nil, stopped_at: nil, stopped_by: nil)
      Designs::SetupRunJob.perform_later(setup.id)
    elsif setup&.failed?
      setup.update!(status: "approved", error: nil, unit_job_id: nil, unit_deadline_at: nil)
      setup.features.where(status: "running").update_all(status: "todo")
      setup.start_work!
    end
    return redirect_to(workshop_designs_overview_path(thread: setup.design_thread_id)) if setup&.design_thread

    redirect_to setup ? helpers.import_page_path(setup) : workshop_design_setup_run_path
  end

  # A full rebuild on a thread of its own, which people trim and merge.
  def reimport
    project = @project || current_workshop_project
    thread = project.design_threads.create!(
      author: current_user, title: "Re-import from staging", chat_session: Designs::Threads.new_session(project, current_user),
      branch: Designs::ThreadNames.branch_for(project: project, text: "Re-import from staging"),
      base_sha: Designs::Threads.master_head(project)
    )
    setup = project.design_setups.create!(status: "active", phase: "map", step: 0, started_by: current_user, design_thread: thread)
    Designs::SetupRunJob.perform_later(setup.id)
    flash[:clar_toast] = "Re-import queued · staging and #{app_repos(project).first || 'the app'}"
    redirect_to workshop_designs_overview_path(thread: thread.id)
  end

  private

  # Resume (Kacper, 2026-11-22): what the stop cut short (the feature it was
  # building, failed by its killed turn) is built again.
  def resume_stopped!(setup)
    setup.features.where(status: "failed").where(finished_at: setup.stopped_at..).find_each do |feature|
      feature.update!(status: "todo", stage: nil, error: nil, finished_at: nil)
    end
  end

  def refuse_while_running
    return unless current_workshop_project.design_setups.running.exists?

    flash[:clar_toast] = "A setup is already running. It goes on from where it is."
    redirect_to workshop_design_setup_run_path
  end

  # "Started today at 16:40 · staging.acme.test, as Admin and Member".
  def where_line(roles)
    started = @setup.created_at.in_time_zone
    day = started.to_date == Time.zone.today ? "today" : started.strftime("%-d %b")
    host = begin
      URI.parse(@project.design_app_url.to_s).host
    rescue URI::InvalidURIError
      nil
    end
    place = [ host, ("as #{roles.map(&:name).to_sentence}" if roles.any?) ].compact.join(", ").presence
    [ "Started #{day} at #{started.strftime('%H:%M')}", place ].compact.join(" · ")
  end

  def incomplete
    flash.now[:alert] = @refusal || INCOMPLETE
    render :new, status: :unprocessable_entity
  end

  def app_repos(project)
    Array(project.design_app_repos).filter_map { |repo| repo["repo"] if repo.is_a?(Hash) }
  end

  def form_params
    params.permit(:framework, :framework_version, :ui, :ui_version, :repo, :repo_token,
                  repos: %i[role url], contexts: %i[id name url login password code_only])
  end

  def save_form
    form = Designs::SetupForm.new(@project, form_params)
    form.save.tap { |saved| @refusal = form.error unless saved }
  end
end
