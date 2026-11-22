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
  # A finished thread shows its accepted copy (2026-11-21).
  FINISHED_MODES = %w[accepted changes].freeze

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

    @way_back = way_back
    @threads = @project.design_threads.open.includes(:task).order(updated_at: :desc)
    # Finished threads stay, at the bottom, greyed (Kacper, 2026-11-21).
    @finished = @project.design_threads.merged.includes(:task).order(merged_at: :desc, id: :desc)
    @deleted = @project.design_threads.deleted.order(deleted_at: :desc)
    @merges = @project.design_merges.newest_first.includes(:user, :task)
    @tab = params[:tab].presence_in(TABS) || "canvas"
    load_imports if @tab == "imports"
    @behind = @thread ? Designs::Threads.behind(@thread) : []
    # An acceptance under way: the header says so, Accept and the composer step aside.
    @accepting = @thread && Designs::Threads.acceptance(@thread).present?
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
    finished = @thread&.merged?
    @ahead = live && @repo.head(@thread.branch, lock: false) ? @repo.commits_ahead(@thread.branch, lock: false) : 0
    if finished
      @mode = params[:mode].presence_in(FINISHED_MODES) || "accepted"
      @slot = finished_slot(@thread)
    else
      @mode = live ? (params[:mode].presence_in(MODES) || "branch") : "master"
      @slot = @mode == "master" ? Designs::Repo::MASTER : @thread.branch
    end
    # A branch is published once a turn commits to it. Until then it is master
    # as it was, so its canvas shows master's screens.
    @master_for_branch = @slot != Designs::Repo::MASTER && @ahead.zero? && !@publisher.published?(@slot)
    @slot = Designs::Repo::MASTER if @master_for_branch
    screens = published_screens(@slot)
    @contexts = screens[:contexts]
    @screens = screens[:screens]
    @context, @screen = pick_screen
    @changed, @changed_own, @changed_through =
      if live then changed_screens(@thread.branch)
      elsif finished && @slot != Designs::Repo::MASTER then changed_screens(@slot)
      else [ [], [], {} ]
      end
    @current = @screens.find { |s| s[:context] == @context && s[:id] == @screen }
    return unless @current

    changes = @mode == "changes" && @changed.include?([ @context, @screen ])
    @frame_path = "designs/#{@context}/#{@screen}#{'.changes' if changes}.html"
    @frame_src = @publisher.grant_url(@slot, @frame_path)
  rescue Designs::Publisher::Error, ArgumentError
    @frame_src = nil
  end

  # A finished thread's copy: its accepted copy, else (merged before those
  # existed) its branch's, else master.
  def finished_slot(thread)
    [ "accepted/#{thread.id}", thread.branch ].find { |slot| slot.present? && @publisher.published?(slot) } || Designs::Repo::MASTER
  rescue ArgumentError
    Designs::Repo::MASTER
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
  # The components master's screens use, straight or through another
  # component, each with how many screens use it: a setup can leave
  # components behind that no screen shows.
  def components_in(master)
    return [] unless master

    screens = Dir.glob("designs/*/*.html", base: master.to_s).reject { |path| path.end_with?(".changes.html") }.map { |path| master.join(path).read }
    inside = Hash.new do |found, name|
      found[name] = Set[name]
      file = master.join("components/#{name}/#{name}.html")
      found[name] = components_named(file.read).reduce(Set[name]) { |all, more| all | found[more] } if file.file?
      found[name]
    end
    uses = screens.map { |html| components_named(html).reduce(Set.new) { |all, name| all | inside[name] } }
    Dir.glob("components/*/", base: master.to_s).sort.filter_map do |dir|
      name = File.basename(dir)
      used = uses.count { |names| names.include?(name) }
      next if used.zero?

      preview = %W[components/#{name}/preview.html components/#{name}/#{name}.html].find { |path| master.join(path).file? }
      { name: name, path: "components/#{name}/#{name}.html", preview: preview && @publisher.grant_url(Designs::Repo::MASTER, preview), used: used }
    end
  end

  def components_named(html)
    html.scan(%r{components/([\w-]+)/}).flatten.to_set
  end

  # Back beside "Designs": the last page outside Designs the person came
  # from, kept while they move around inside, else the Workshop. With the
  # menus hidden it is their way out.
  def way_back
    from = URI.parse(request.referer.to_s) rescue nil
    if from.is_a?(URI::HTTP) && from.host == request.host && !from.path.to_s.start_with?("/workshop/designs")
      session[:designs_way_back] = from.request_uri
    end
    session[:designs_way_back] || workshop_path
  end

  def published_screens(slot)
    file = @publisher.slot_folder(slot)&.join("__flosis/screens.json")
    return { contexts: [], screens: [] } unless file&.file?

    JSON.parse(file.read, symbolize_names: true).slice(:contexts, :screens).transform_values { Array(_1) }
  rescue JSON::ParserError
    { contexts: [], screens: [] }
  end

  # [all, own, through]: every changed screen, as [context, screen]; the ones
  # the thread changed itself, as [context, screen, "new" | "updated"]; and the
  # ones only a changed component reached, by component. A preview published
  # before the record (__flosis/changes.json) has every screen as its own.
  def changed_screens(slot)
    folder = @publisher.slot_folder(slot) or return [ [], [], {} ]
    all = Dir.glob("designs/*/*.changes.html", base: folder.to_s).sort.map do |path|
      _, context, file = path.split("/")
      [ context, file.delete_suffix(".changes.html") ]
    end
    record = folder.join("__flosis/changes.json")
    return [ all, all.map { |pair| [ *pair, "updated" ] }, {} ] unless record.file?

    data = JSON.parse(record.read)
    [ all, Array(data["own"]), data["through"].is_a?(Hash) ? data["through"] : {} ]
  rescue JSON::ParserError
    [ all, all.map { |pair| [ *pair, "updated" ] }, {} ]
  end

  # The screen asked for, else where the thread was last, else the first. A
  # role asked for by name stays (View as, Kacper 2026-11-22: a role with no
  # screen in common with the others could not be opened at all): without
  # that screen it opens its closest one, and says so when another role has it.
  def pick_screen
    asked = params[:ctx].presence
    wanted = [ asked || @thread&.focus_context, params[:screen].presence || @thread&.focus_screen ]
    found = @screens.find { |s| [ s[:context], s[:id] ] == wanted }
    if !found && asked && (found = closest_screen(asked, wanted[1]))
      say_instead(wanted[1], found)
    end
    found ||= @screens.find { |s| s[:id] == wanted[1] } ||
              @screens.find { |s| s[:context] == wanted[0] } ||
              @screens.first
    found ? [ found[:context], found[:id] ] : [ nil, nil ]
  end

  # A role's way in when it has no screen of the area asked for.
  HOME_SCREENS = %w[overview dashboard home index].freeze

  # The role's screen of the same area as id: the longest run of leading
  # words their names share, the plainest of those (configuration for
  # configuration-jira, idea before idea-details); else its overview, else its
  # first. nil when the role has no screens.
  def closest_screen(context, id)
    own = @screens.select { |s| s[:context] == context }
    words = id.to_s.split("-")
    shared = ->(screen) { screen[:id].split("-").zip(words).take_while { |mine, theirs| mine == theirs }.size }
    near = own.select { |s| shared.(s).positive? }.min_by { |s| [ -shared.(s), s[:id].count("-") ] }
    near || HOME_SCREENS.lazy.filter_map { |home| own.find { |s| s[:id] == home } }.first || own.first
  end

  # The canvas shows another screen than the one asked for, which another
  # role has: it says which (a toast).
  def say_instead(id, shown)
    elsewhere = @screens.find { |s| s[:id] == id } or return
    flash.now[:clar_toast] ||= "#{elsewhere[:name]} is not available as #{helpers.designs_context_name(@contexts, shown[:context])} · showing #{shown[:name]}"
  end
end
