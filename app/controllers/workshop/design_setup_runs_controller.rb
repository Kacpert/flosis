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

  FRAMEWORKS = [ [ "vue", "Vue.js", "3.4" ], [ "react", "React", "18.3" ], [ "angular", "Angular", "17" ], [ "html", "HTML + CSS", nil ] ].freeze
  UI_SYSTEMS = [ [ "foundation", "Foundation", "6.8" ], [ "bootstrap", "Bootstrap", "5.3" ], [ "tailwind", "Tailwind", "4" ],
                 [ "material", "Material", "3" ], [ "custom", "Custom", nil ] ].freeze
  SUPPORTED = %w[html tailwind custom].freeze
  INCOMPLETE = "Fill in the designs repository, at least one app repository and one context with URL and login.".freeze
  REPO = %r{\A[\w.-]+/[\w.-]+(@[\w./-]+)?\z}

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

    if setup&.failed? && setup.finished_at.nil?
      setup.update!(status: "active", error: nil, unit_job_id: nil, unit_deadline_at: nil)
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
                  repos: %i[role url], contexts: %i[id name url login password])
  end

  # "github.com/acme/designs", "https://github.com/acme/designs" and
  # "acme/designs" all name acme/designs.
  def repo_name(value)
    value.to_s.strip.sub(%r{\Ahttps?://}, "").sub(%r{\Agithub\.com/}, "").delete_suffix(".git").delete_suffix("/").presence
  end

  def rows(value)
    value.respond_to?(:values) ? value.values : Array(value)
  end

  def save_form
    form = form_params
    repo = repo_name(form[:repo])
    repos = rows(form[:repos]).filter_map do |row|
      name = repo_name(row[:url])
      { "role" => row[:role].to_s.strip.presence || "Repository", "repo" => name } if name&.match?(REPO)
    end
    contexts = rows(form[:contexts]).select { |row| row[:name].present? && row[:url].present? && row[:login].present? }
    roles = @project.design_setup_roles.index_by { |role| role.id.to_s }
    return false unless repo&.match?(REPO) && repos.any? && contexts.any?
    return false if contexts.any? { |row| row[:password].blank? && !roles.key?(row[:id].to_s) }

    framework = form[:framework].presence_in(SUPPORTED) || "html"
    ui = form[:ui].presence_in(SUPPORTED) || "tailwind"
    Project.transaction do
      @project.update!(designs_framework: framework, designs_framework_version: form[:framework_version].presence,
                       designs_ui_system: ui, designs_ui_version: form[:ui_version].presence, design_repo: repo,
                       design_app_repos: repos, design_base_kit: ui == "custom" ? "plain" : "tailwind4",
                       design_app_url: origin(contexts.first[:url]), designs_enabled: true)
      @project.update!(design_repo_token: form[:repo_token]) if form[:repo_token].present?
      kept = contexts.each_with_index.map do |row, position|
        role = roles[row[:id].to_s] || @project.design_setup_roles.new
        role.assign_attributes(name: row[:name].strip, login_url: row[:url].strip, username: row[:login].strip, position: position)
        role.password = row[:password] if row[:password].present?
        role.save!
        role.id
      end
      @project.design_setup_roles.where.not(id: kept).destroy_all
    end
    true
  rescue ActiveRecord::RecordInvalid => e
    # What only the record can judge (the target being one of the app's own
    # repositories) is said on the form; it used to escape as a bare 422.
    @refusal = e.record.errors.full_messages.to_sentence
    false
  end

  def origin(url)
    uri = URI.parse(url.to_s.strip)
    uri.host ? "#{uri.scheme}://#{uri.host}#{":#{uri.port}" unless uri.default_port == uri.port}" : url
  rescue URI::InvalidURIError
    url
  end
end
