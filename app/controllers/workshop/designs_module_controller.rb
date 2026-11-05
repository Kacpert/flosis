# The Designs module of the Workshop's current project (Workshop Designs v2,
# after Kacper's ClearBacklog-3.html): on the left the threads, or one thread's
# conversation; on the right the canvas (a published screen, sandboxed, under a
# grant) or a library page (design system, components, merge history).
#
# Until Flosis staff switch Designs on for a project, only they see it.
class Workshop::DesignsModuleController < Workshop::BaseController
  before_action { require_permission!(:designs) }
  include DesignsVisibility

  TABS = %w[system components history imports].freeze
  MODES = %w[branch master changes].freeze

  def show
    @project = current_workshop_project
    DesignTurn.fail_stale!
    import = @project.design_setups.first_imports.order(:id).last
    return redirect_to(workshop_design_setup_run_path) if import && !import.done? && (import.running? || !@project.designs_ready?)
    return render(:not_set_up) unless @project.designs_ready?

    @repo = Designs::Repo.new(@project)
    @publisher = Designs::Publisher.new(@project, @repo)
    @thread = @project.design_threads.live.find_by(id: params[:thread]) if params[:thread].present?
    return render(partial: "messages", locals: { thread: @thread }) if params[:frame] == "messages" && @thread

    @threads = @project.design_threads.open.includes(:task).order(updated_at: :desc)
    @deleted = @project.design_threads.deleted.order(deleted_at: :desc)
    @merges = @project.design_merges.newest_first.includes(:user, :task)
    @tab = params[:tab].presence_in(TABS) || "canvas"
    load_imports if @tab == "imports"
    @behind = @thread ? Designs::Threads.behind(@thread) : []
    @description_change = @thread && Designs::Threads.description_change(@thread)
    @rows = @threads.map { |thread| row_for(thread) }
    @back = @project.tasks.pipeline.find_by(id: params[:back]) if params[:back].present?
    load_canvas
    load_library
  end

  private

  # Imports (Designs imports): every import, newest first, and the one asked
  # for, which counts as opened by whoever looks at it.
  def load_imports
    @imports = @project.design_setups.newest_first.includes(:features, :since_setup).to_a
    @import = @imports.find { |setup| setup.id.to_s == params[:import].to_s } if params[:import].present?
    @import&.seen_by!(current_user)
  end

  # What a thread's row in the list shows beside its title.
  def row_for(thread)
    {
      thread: thread,
      task_changed: Designs::Threads.description_change(thread).present?,
      master_changed: Designs::Threads.behind(thread).any?
    }
  end

  def load_canvas
    live = @thread&.open? && !@thread.fresh?
    @ahead = live && @repo.head(@thread.branch, lock: false) ? @repo.commits_ahead(@thread.branch, lock: false) : 0
    @mode = live ? (params[:mode].presence_in(MODES) || "branch") : "master"
    @slot = @mode == "master" ? Designs::Repo::MASTER : @thread.branch
    screens = published_screens(@slot)
    @contexts = screens[:contexts]
    @screens = screens[:screens]
    @context, @screen = pick_screen
    @changed = live ? changed_screens(@thread.branch) : []
    @current = @screens.find { |s| s[:context] == @context && s[:id] == @screen }
    return unless @current

    changes = @mode == "changes" && @changed.include?([ @context, @screen ])
    @frame_path = "designs/#{@context}/#{@screen}#{'.changes' if changes}.html"
    @frame_src = @publisher.grant_url(@slot, @frame_path)
  rescue Designs::Publisher::Error, ArgumentError
    @frame_src = nil
  end

  # The screens a published slot lists (__flosis/screens.json), as
  # { contexts: [{id:, name:}], screens: [{id:, context:, name:, path:}] }.
  FRAMEWORKS = { "html" => "HTML + CSS", "vue" => "Vue.js", "react" => "React", "angular" => "Angular" }.freeze
  UI_SYSTEMS = { "tailwind" => "Tailwind", "custom" => "Custom", "foundation" => "Foundation", "bootstrap" => "Bootstrap", "material" => "Material" }.freeze

  # What the library pages and the settings drawer read: master's tokens and
  # components, the stack and where the designs came from.
  def load_library
    @setup = @project.design_setups.order(:id).last
    @app_repos = Array(@project.design_app_repos).map { |repo| repo.is_a?(Hash) ? repo["repo"] : repo.to_s }.presence || [ @project.github_repo ].compact
    ui = UI_SYSTEMS.fetch(@project.designs_ui_system, @project.designs_ui_system.to_s.humanize)
    @stack = { framework: FRAMEWORKS.fetch(@project.designs_framework, @project.designs_framework.to_s.humanize),
               framework_version: @project.designs_framework_version, ui: ui, ui_version: @project.designs_ui_version,
               styles: "#{ui == 'Tailwind' ? 'Tailwind CSS' : 'CSS'} · tokens in design-system/" }
    master = @publisher.slot_folder(Designs::Repo::MASTER)
    @tokens = tokens_in(master&.join("design-system/theme.css"))
    @screen_count = master ? Dir.glob("designs/*/*.html", base: master.to_s).count { |path| !path.end_with?(".changes.html") } : 0
    @components = components_in(master)
    return unless @thread&.open? && !@thread.fresh? && !@thread.task

    names = @changed.map { |context, screen| [ helpers.designs_context_name(@contexts, context), helpers.designs_screen_name(@screens, context, screen) ] }
    @generate_draft = Designs::GeneratedTask.draft(@thread, changed: names)
  end

  # A colour as a theme writes one, and nothing else: the swatch puts it in a
  # style attribute on the app's own page.
  COLOUR = /\A(#\h{3,8}|(rgba?|hsla?|oklch|oklab|lab|lch|color)\([\w\s.,%\/+-]*\)|[a-z]+)\z/i

  # The theme's custom properties, by what they are for.
  def tokens_in(file)
    pairs = file&.file? ? file.read.scan(/--([\w-]+)\s*:\s*([^;]+);/).map { |name, value| [ name, value.strip ] } : []
    {
      colors: pairs.select { |name, value| name.start_with?("color-") && COLOUR.match?(value) }.map { |name, value| [ name.delete_prefix("color-"), value ] },
      type: pairs.select { |name, _| name.start_with?("font-", "text-", "leading-", "tracking-") },
      spacing: pairs.select { |name, _| name.start_with?("spacing") },
      radius: pairs.select { |name, _| name.start_with?("radius") }
    }
  end

  # master's components, each with its preview and how many screens use it.
  def components_in(master)
    return [] unless master

    screens = Dir.glob("designs/*/*.html", base: master.to_s).reject { |path| path.end_with?(".changes.html") }.map { |path| master.join(path).read }
    Dir.glob("components/*/", base: master.to_s).sort.map do |dir|
      name = File.basename(dir)
      preview = %W[components/#{name}/preview.html components/#{name}/#{name}.html].find { |path| master.join(path).file? }
      { name: name, path: "components/#{name}/#{name}.html",
        preview: preview && @publisher.grant_url(Designs::Repo::MASTER, preview),
        used: screens.count { |html| html.include?("components/#{name}/") } }
    end
  end

  def published_screens(slot)
    file = @publisher.slot_folder(slot)&.join("__flosis/screens.json")
    return { contexts: [], screens: [] } unless file&.file?

    JSON.parse(file.read, symbolize_names: true).slice(:contexts, :screens).transform_values { Array(_1) }
  rescue JSON::ParserError
    { contexts: [], screens: [] }
  end

  def changed_screens(slot)
    folder = @publisher.slot_folder(slot) or return []
    Dir.glob("designs/*/*.changes.html", base: folder.to_s).sort.map do |path|
      _, context, file = path.split("/")
      [ context, file.delete_suffix(".changes.html") ]
    end
  end

  # The screen asked for, else where the thread was last, else the first.
  def pick_screen
    wanted = [ params[:ctx].presence || @thread&.focus_context, params[:screen].presence || @thread&.focus_screen ]
    found = @screens.find { |s| [ s[:context], s[:id] ] == wanted } ||
            @screens.find { |s| s[:id] == wanted[1] } ||
            @screens.find { |s| s[:context] == wanted[0] } ||
            @screens.first
    found ? [ found[:context], found[:id] ] : [ nil, nil ]
  end
end
