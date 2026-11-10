require "tempfile"

# What a design turn is for, and what differs with it (Designs::TurnJob runs
# every kind): a thread's turn works on the thread's branch, a task's on
# wip/<slug>, both on the project's own key, with file tools and a copy of the
# app's checkout; a setup run's works on wip/setup (or its re-import's
# thread), with the phase's prompt, the repositories the run cloned, and a
# browser on the client's test environment. Everything else is the same turn.
#
# A subject composes the library once (Rulings P3-R1, P5-R4): the prompt
# Claude gets, the texts the leak guard refuses and the versions the turn
# records are one read.
module Designs::Subject
  module_function

  def for(chat_session)
    case chat_session.purpose
    when "designs_setup" then SetupSubject.new(chat_session)
    when "designs_thread" then ThreadSubject.new(chat_session)
    else TaskSubject.new(chat_session)
    end
  end

  # Workshop Designs v2: a design thread's turn works on the thread's branch,
  # made from the master commit the thread is based on, on the project's own
  # key. It is published with its Changes against that base, and its reply
  # names the screens the turn changed.
  class ThreadSubject
    NO_THREAD = "This conversation has no design thread.".freeze

    attr_reader :thread

    def initialize(session)
      @session = session
      @thread = session.design_thread || raise(Designs::TurnJob::Failure, NO_THREAD)
    end

    def project = @thread.project
    def slug = @thread.branch.delete_prefix(Designs::ThreadNames::PREFIX)
    def wip_branch = @thread.branch
    def preview_slot = @thread.branch
    def base_branch_for_new_worktree = @thread.base_sha.presence || Designs::Repo::MASTER
    def publish_base = @thread.base_sha.presence

    def checkout!(repo)
      repo.synchronize do
        repo.ensure_clone!
        repo.worktree!(wip_branch, from: base_branch_for_new_worktree).tap { repo.follow_origin!(wip_branch) }
      end
    end

    def composition
      @composition ||= Designs::Library.compose(project)
    end

    def system_text = Designs::Prompt.system_text(project: project, composition: composition)
    def forbidden_texts = composition.texts
    def library_version_ids = composition.version_ids
    def api_key = ProjectCredentials.new(project).designs_api_key
    def add_dirs = []
    def secrets = ProjectCredentials.new(project).all_secrets
    def prepare! = nil

    # The turn is given the design repo as it starts (Designs::RepoMap): the
    # theme and the screen in view whole on its session's first turn, when
    # nothing of the repo is in the conversation yet. A design turn builds
    # screens only; components come in a turn of their own, before merging.
    def turn_message(request, turn: nil, worktree: nil)
      first = turn && turn.chat_session.design_turns.where.not(id: turn.id).where.not(started_at: nil).none?
      map = worktree && Designs::RepoMap.text(worktree, focus: focus_path, full: first)
      Designs::Prompt.thread_message(thread: @thread, request: request, repo_map: map, screens_only: turn&.kind == "design")
    end

    # The screen the person has open, as a path in the repo; nil unless both
    # its parts are names a screen can have (they come from the request).
    def focus_path
      parts = [ @thread.focus_context, @thread.focus_screen ]
      "designs/#{parts.join("/")}.html" if parts.all? { |part| Designs::Screens::ID.match?(part.to_s) }
    end

    # File tools, the app's checkout copied for the turn, no browser and a
    # thread turn's bounds. The file tools are all it has (tool_set): no
    # subagent, which spent minutes mapping a repo Claude then read itself.
    def tools = Designs::TurnJob::TOOLS
    def tool_set = Designs::TurnJob::TOOLS
    def with_mcp(_worktree) = yield(nil)
    def timeout = DesignTurn.turn_timeout
    def budget_usd = DesignTurn.turn_budget_usd
    def app_copy? = true

    # The thread is based on the master commit its branch last took in: a turn
    # that resolved a merge with master moves it. Read before the branch is
    # published, so Changes is drawn against the new base.
    def refresh_base(repo)
      base = repo.merge_base(wip_branch, Designs::Repo::MASTER)
      @thread.update!(base_sha: base) if base && base != @thread.base_sha
    end

    def after_turn(repo)
      refresh_base(repo)
      Designs::SyncJiraLinksJob.perform_later(@thread.task_id) if @thread.task&.external_reference.present?
    end

    # The screens the turn changed, from the commit it started on to the one
    # it made, as chips: [screen, context, "M" | "+"]. A screen counts only if
    # it also differs from the thread's base, so what master brought in is not
    # put down to the turn. The first becomes where the thread opens.
    def chips(repo, from, to)
      return [] unless to

      before = from ? screens_at(repo, from) : Designs::Screens.new(paths: [], reader: ->(_path) { nil })
      head = screens_at(repo, to)
      own = Designs::Changes.new(base: screens_at(repo, @thread.base_sha.presence || Designs::Repo::MASTER), head: head)
                            .changed.map { |change| [ change[:context], change[:screen] ] }
      chips = Designs::Changes.new(base: before, head: head).changed.filter_map do |change|
        [ change[:screen], change[:context], change[:kind] == "new" ? "+" : "M" ] if own.include?([ change[:context], change[:screen] ])
      end
      @thread.update!(focus_screen: chips.first[0], focus_context: chips.first[1]) if chips.any?
      chips
    end

    private

    def screens_at(repo, ref)
      Designs::Screens.new(paths: repo.ls_files(ref, "designs/"), reader: ->(path) { repo.read_file(ref, path) })
    end
  end

  class TaskSubject
    def initialize(session)
      @session = session
      @task = session.task
    end

    def project = @task.project
    def slug = Designs::BranchNames.slug(@task)
    def wip_branch = Designs::BranchNames.wip(@task)
    def preview_slot = wip_branch

    # Where a first turn branches from (Repo#task_worktree! also takes
    # origin's approved design, which this does not look for).
    def base_branch_for_new_worktree
      design = Designs::BranchNames.design(@task)
      Designs::Repo.new(project).head(design) ? design : Designs::Repo::MASTER
    end

    def checkout!(repo) = repo.task_worktree!(@task)

    def composition
      @composition ||= Designs::Library.compose(project)
    end

    def system_text = Designs::Prompt.system_text(project: project, composition: composition)
    def forbidden_texts = composition.texts
    def library_version_ids = composition.version_ids
    def turn_message(request, **) = Designs::Prompt.turn_message(task: @task, request: request)
    def api_key = ProjectCredentials.new(project).designs_api_key

    # Ruling P5-R1: no folder beyond the per-turn copy of the app.
    def add_dirs = []
    def secrets = ProjectCredentials.new(project).all_secrets
    def prepare! = nil
    # File tools, the app's checkout copied for the turn, no browser and a
    # thread turn's bounds.
    def tools = Designs::TurnJob::TOOLS
    def tool_set = Designs::TurnJob::TOOLS
    def with_mcp(_worktree) = yield(nil)
    def timeout = DesignTurn.turn_timeout
    def budget_usd = DesignTurn.turn_budget_usd
    def app_copy? = true
    def publish_base = nil
    def chips(*) = []
    def refresh_base(_repo) = nil
    def after_turn(_repo) = nil
  end

  class SetupSubject
    NO_SETUP = "This project has no setup run.".freeze
    # The browser's tools (lib/designs_crawler/browser.mjs), as the CLI names
    # them; only the map's turn may save the features.
    BROWSER_TOOLS = %w[open click fill_form screenshot design click_design compare check_design progress].map { |name| "mcp__flosis_browser__#{name}" }.freeze
    # The base prompt says a turn has no browser; this one has.
    BROWSER_NOTE = <<~TEXT.freeze
      # This turn's browser

      This turn has a browser: the flosis_browser tools, signed in to the client's test environment as each context of the run. What the base prompt says about opening no browser does not hold for this turn; everything else in it does. A context's designs go in the folder the message names for it, never in a folder named after its browser slug.
    TEXT
    # A feature's turn may stop on what only the person can fix (Designs
    # imports): its feature waits for their answer while the import goes on.
    # A re-import's may not: nobody answers on its page; it is fixed on its
    # thread.
    BLOCKED_NOTE = <<~TEXT.freeze
      # When only the person can unblock the feature
      If the feature cannot be built honestly because of something only the person can fix on the test account (an integration that is not connected, data you cannot create there, a context that cannot reach the feature), stop building it. Keep what you built so far, and end the turn with one <blocked> block: a single question for the person, saying what to fix and where. They will answer, and a later turn goes on from where you stopped. A gap you can build around from the code is a <missing> note, not a <blocked> block.
    TEXT
    MAP_TOOLS = %w[mcp__flosis_browser__save_features].freeze
    PHASE_TITLES = { "map" => "the feature map", "design_system" => "the design system", "feature" => "one feature",
                     "resync" => "what changed in the app" }.freeze
    # The phases whose turn saves features: the map, and a resync's look at
    # what changed.
    SAVING = %w[map resync].freeze
    VIEWPORT = { width: 1440, height: 900 }.freeze

    def initialize(session)
      @session = session
    end

    def project = @session.project
    def slug = "setup"
    # A re-import (Workshop Designs v2) works on its own thread's branch, and
    # a feature built after its import (Designs imports) on its own.
    def wip_branch = feature&.branch.presence || setup.design_thread&.branch || Designs::BranchNames::SETUP
    def preview_slot = wip_branch
    def base_branch_for_new_worktree
      return Designs::Repo::MASTER if feature&.branch.present?

      setup.design_thread&.base_sha.presence || Designs::Repo::MASTER
    end

    # The import the turn's session was made for; a session from before
    # sessions knew theirs has the run's latest active setup.
    def setup
      @setup ||= @session.design_setup || project.design_setups.active.order(:id).last || raise(Designs::TurnJob::Failure, NO_SETUP)
    end

    # The feature the run is building, if any.
    def feature
      return @feature if defined?(@feature)

      @feature = setup.features.find_by(status: "running")
    end

    # wip/setup, made off master when neither this clone nor origin has it.
    def checkout!(repo)
      repo.synchronize do
        repo.ensure_clone!
        repo.worktree!(wip_branch, from: base_branch_for_new_worktree)
      end
    end

    def composition
      @composition ||= Designs::Library.compose_setup(setup.phase)
    end

    def system_text
      "#{Designs::Prompt.system_text(project: project, composition: composition)}\n#{readable}\n#{BROWSER_NOTE}" \
        "#{"\n#{BLOCKED_NOTE}" if setup.phase == 'feature' && !setup.reimport?}"
    end

    def forbidden_texts = composition.texts
    def library_version_ids = composition.version_ids

    # The stack, the app's repositories and the contexts, by the slugs the
    # browser knows them by, come with every setup turn; the request is last.
    def turn_message(request, **)
      ui = Workshop::DesignsModuleController::UI_SYSTEMS.fetch(project.designs_ui_system, project.designs_ui_system.to_s.humanize)
      framework = Workshop::DesignsModuleController::FRAMEWORKS.fetch(project.designs_framework, project.designs_framework.to_s.humanize)
      repos = Array(project.design_app_repos).filter_map { |row| "#{row['role']}: #{row['repo']}" if row.is_a?(Hash) }
      contexts = project.design_setup_roles.map do |role|
        "#{role.name}: browser #{Designs::SignIn.slug(role)}, designs/#{role.name.parameterize.presence || "context-#{role.position.to_i + 1}"}/"
      end
      <<~MESSAGE
        ## Setup run
        This turn: #{PHASE_TITLES.fetch(setup.phase, setup.phase.humanize.downcase)}

        ## Stack
        #{[ framework, project.designs_framework_version ].compact_blank.join(' ')} with #{[ ui, project.designs_ui_version ].compact_blank.join(' ')}

        ## App repositories
        #{repos.join("\n").presence || "(the project's own repository)"}

        ## Contexts
        #{contexts.join("\n").presence || "(none)"}

        ## Request
        #{request.to_s.strip}
      MESSAGE
    end

    def tools = Designs::TurnJob::TOOLS + BROWSER_TOOLS + (SAVING.include?(setup.phase) ? MAP_TOOLS : [])
    # The CLI's own set of tools, beside the browser's.
    def tool_set = nil
    def timeout = DesignTurn.setup_timeout
    def budget_usd = DesignTurn.setup_budget_usd
    # The app comes from the repositories the run cloned (add_dirs).
    def app_copy? = false

    # The turn's browser: its config written beside the run's states (no
    # password is in it), and the CLI's MCP config in the system's temp folder,
    # gone when the turn is done. A killed turn's is swept with its prompt's.
    def with_mcp(worktree)
      FileUtils.mkdir_p(setup.run_dir)
      File.chmod(0o700, setup.run_dir)
      config = setup.run_dir.join("browser.json")
      File.write(config, JSON.generate(browser_config(worktree)), perm: 0o600)
      server = { command: "node", args: [ File.join(Designs::SignIn.crawler_dir, "browser.mjs") ],
                 env: Designs::SignIn.node_env.merge("FLOSIS_BROWSER_CONFIG" => config.to_s) }
      Tempfile.create([ "#{Designs::TurnJob::PROMPT_PREFIX}-mcp", ".json" ]) do |file|
        file.write(JSON.generate(mcpServers: { flosis_browser: server }))
        file.close
        yield file.path
      end
    end

    # The project's own key, as its turns use; Flosis's setup key for a
    # project that has none; with neither, the server's Claude login.
    def api_key = ProjectCredentials.new(project).designs_api_key || ENV["FLOSIS_DESIGNS_SETUP_API_KEY"].presence

    # The app's repositories the run cloned and the materials, all read-only.
    def add_dirs
      [ *Designs::AppRepos.new(setup).dirs, materials_dir.to_s, changes_dir.to_s ].select { |dir| File.directory?(dir) }
    end

    # Every credential of the project, and every role's password.
    def secrets
      (ProjectCredentials.new(project).all_secrets + project.design_setup_roles.map(&:password)).compact.uniq
    end

    # A re-import shows its Changes against its thread's base.
    def publish_base = setup.design_thread&.base_sha.presence
    def chips(*) = []
    def refresh_base(_repo) = nil
    def after_turn(_repo) = nil

    # The materials are copied out of Active Storage before each turn, afresh
    # (a removed one goes), and left read-only: files 0444, folders 0555.
    def prepare!
      dir = materials_dir
      FileUtils.chmod_R("u+w", dir) if dir.exist?
      FileUtils.rm_rf(dir)
      return unless project.design_materials.attached?

      FileUtils.mkdir_p(dir)
      project.design_materials.each do |material|
        path = dir.join(material.filename.sanitized)
        File.binwrite(path, material.download)
        File.chmod(0o444, path)
      end
      File.chmod(0o555, dir)
    end

    private

    def materials_dir
      Pathname(project.designs_dir).join("design-materials")
    end

    # A resync's diffs of the app since the import it starts from.
    def changes_dir = setup.run_dir.join("changes")

    # What the browser is given: the test environment, each context that
    # signed in (its state, never its password), the worktree its designs are
    # served from, and where it writes the feature's progress and the map.
    def browser_config(worktree)
      contexts = project.design_setup_roles.filter_map do |role|
        slug = Designs::SignIn.slug(role)
        state = setup.run_dir.join("auth", "#{slug}.json")
        { slug: slug, name: role.name, statePath: state.to_s } if state.file?
      end
      { baseUrl: project.design_app_url, contexts: contexts, worktree: worktree.to_s,
        progressPath: setup.run_dir.join("progress.json").to_s,
        featuresPath: (setup.run_dir.join("features.json").to_s if SAVING.include?(setup.phase)),
        featureKey: feature&.key, viewport: VIEWPORT }
    end

    def readable
      lines = []
      Designs::AppRepos.new(setup).dirs.each { |dir| lines << "- The app's code: #{dir}" }
      lines << "- Materials the team uploaded: #{materials_dir}" if project.design_materials.attached?
      lines << "- What changed in the app since the last import: #{changes_dir}" if changes_dir.directory?
      Array(project.design_figma_urls).each { |url| lines << "- Figma: #{url}" }
      return "" if lines.empty?

      "\n# What you can read for this run (read-only)\n\n#{lines.join("\n")}\n"
    end
  end
end
