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
  # A thread's design turn can copy a file of its repo (flosis_files, Kacper
  # 2026-11-19): a new screen starts from the closest one.
  COPY_TOOL = "mcp__flosis_files__copy_file".freeze
  # A thread's check (2026-11-21) looks at the screens a turn changed in a
  # browser on the design repo only (lib/designs_crawler/browser.mjs in its
  # design-only mode), at the canvas's size.
  CHECK_TOOLS = %w[design design_shot click_design check_design].map { |name| "mcp__flosis_browser__#{name}" }.freeze
  CHECK_VIEWPORT = { width: 1160, height: 860 }.freeze

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
    # Its preview opens on what it changed, as work in progress (2026-11-21).
    def publish_page = { title: Designs::Threads.page_title(@thread), status: "In progress" }

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
    # A design turn the person's message started may be answered with a
    # proposal (variant b), unless it answers a plan or a proposal. A check
    # runs in a session of its own and is given only what it looks at; the
    # turn after a check that changed something is told what it changed.
    def turn_message(request, turn: nil, worktree: nil)
      return Designs::Prompt.thread_message(thread: @thread, request: request, check: true) if turn&.check?

      first = turn && turn.chat_session.design_turns.where.not(id: turn.id).where.not(started_at: nil).where.not(kind: "check").none?
      after_plan = after_plan?(turn)
      Designs::Prompt.thread_message(thread: @thread, request: request, repo_map: (repo_map(worktree, first) if worktree),
                                     design: turn&.kind == "design", after_plan: after_plan, plan: turn&.plan? || false,
                                     may_propose: (turn&.kind == "design" && turn.may_propose && !after_plan) || false,
                                     check_note: check_note(turn))
    end

    # What the check right before this turn changed, as it said it: nil when
    # there was none, or it changed nothing.
    def check_note(turn)
      return unless turn

      last = turn.chat_session.design_turns.where("id < ?", turn.id).order(:id).last
      return unless last&.check? && last.succeeded? && last.commit_sha.present?

      said = turn.chat_session.chat_messages.where(role: "assistant", kind: "summary").where("id > ?", last.chat_message_id)
                 .order(:id).detect { |message| message.data&.dig("check") }&.content
      "An on-screen check after your last turn changed this: #{said}" if said.present?
    end

    # A design turn whose turn before it is a plan, or a proposal, that
    # finished: what comes now answers it. Earlier tries at the same message
    # (Try again) and checks are passed over.
    def after_plan?(turn)
      return false unless turn&.kind == "design"

      turn.chat_session.design_turns.where("id < ?", turn.id).where.not(chat_message_id: turn.chat_message_id)
          .where.not(kind: "check").order(:id).last&.awaits_answer? || false
    end

    # Only a help to Claude: a map that cannot be made is left out, and the
    # turn goes on without it.
    def repo_map(worktree, full)
      Designs::RepoMap.text(worktree, focus: focus_path, full: full)
    rescue StandardError => e
      Rails.logger.warn("[Designs::Subject] no map of the design repo for #{@thread.branch}: #{e.class}: #{e.message}")
      nil
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
    def tools = Designs::TurnJob::TOOLS + [ COPY_TOOL ]
    def tool_set = Designs::TurnJob::TOOLS

    # copy_file, from flosis_files on the turn's worktree; a plan only reads,
    # so it has none; a check has the design browser instead. The CLI's
    # config is a temp file, gone with the turn, and so is the browser's.
    def with_mcp(worktree, read_only: false, browser: false, &block)
      return yield(nil) if read_only
      return with_browser(worktree, &block) if browser

      server = { command: "node", args: [ File.join(Designs::SignIn.crawler_dir, "files.mjs") ],
                 env: Designs::SignIn.node_env.merge("FLOSIS_FILES_ROOT" => worktree.to_s) }
      mcp_config({ flosis_files: server }, &block)
    end

    # The browser on the design repo only: no app, no sign-in, nothing it can
    # reach but the worktree's designs.
    def with_browser(worktree, &block)
      Tempfile.create([ "#{Designs::TurnJob::PROMPT_PREFIX}-browser", ".json" ]) do |config|
        File.chmod(0o600, config.path)
        config.write(JSON.generate(designOnly: true, worktree: worktree.to_s, viewport: CHECK_VIEWPORT))
        config.close
        server = { command: "node", args: [ File.join(Designs::SignIn.crawler_dir, "browser.mjs") ],
                   env: Designs::SignIn.node_env.merge("FLOSIS_BROWSER_CONFIG" => config.path) }
        mcp_config({ flosis_browser: server }, &block)
      end
    end

    def mcp_config(servers)
      Tempfile.create([ "#{Designs::TurnJob::PROMPT_PREFIX}-mcp", ".json" ]) do |file|
        file.write(JSON.generate(mcpServers: servers))
        file.close
        yield file.path
      end
    end
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
    # put down to the turn. The first becomes where the thread opens, unless
    # the turn is a check: the person is looking at the preview meanwhile.
    def chips(repo, from, to, move_focus: true)
      return [] unless to

      before = from ? screens_at(repo, from) : Designs::Screens.new(paths: [], reader: ->(_path) { nil })
      head = screens_at(repo, to)
      own = Designs::Changes.new(base: screens_at(repo, @thread.base_sha.presence || Designs::Repo::MASTER), head: head)
                            .own.map { |change| [ change[:context], change[:screen] ] }
      chips = Designs::Changes.new(base: before, head: head).changed.filter_map do |change|
        [ change[:screen], change[:context], change[:kind] == "new" ? "+" : "M" ] if own.include?([ change[:context], change[:screen] ])
      end
      @thread.update!(focus_screen: chips.first[0], focus_context: chips.first[1], focus_state: nil) if chips.any? && move_focus
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
    def with_mcp(_worktree, **) = yield(nil)
    def timeout = DesignTurn.turn_timeout
    def budget_usd = DesignTurn.turn_budget_usd
    def app_copy? = true
    def publish_base = nil
    def publish_page = nil
    def chips(*, **) = []
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
    # A resync's look at what changed works from the code and its history
    # alone (Kacper, 2026-11-22): no browser tools, and this note instead of
    # the browser's.
    # What a turn needs from the person (Kacper, 2026-11-22): the suggest
    # tool, for every setup turn, and when to use it.
    SUGGEST_TOOL = "mcp__flosis_browser__suggest".freeze
    SUGGEST_NOTE = <<~TEXT.freeze
      # When you need something from the person

      If something keeps you from importing the app as it is, and only the person can give it, leave a suggestion with the suggest tool, once per thing, and go on with what you can: a role the run's contexts do not cover (kind context: name the role and the map's features it has), data or an integration the test environment lacks, or a repository you could not read (kind other). Never ask for a password. Nothing else is a suggestion.
    TEXT
    CODE_ONLY_NOTE = <<~TEXT.freeze
      # This turn reads code only

      This turn has no browser: it works from the app's code and its history alone. What the base prompt says about a browser does not apply to it.
    TEXT
    # Read-only git on the app's history (Kacper, 2026-11-22: "dobrze żeby
    # miał po prostu dostęp do gita"): lib/designs_crawler/git.mjs on the
    # project's clones (Designs::AppHistory), for every setup turn once they
    # exist. Turns have no shell: this is their only git.
    GIT_TOOL = "mcp__flosis_git__git".freeze
    GIT_NOTE = <<~TEXT.freeze
      # The app's history

      The git tool runs read-only git on the app's repositories, with their whole history: log, show, diff, blame, grep and the like. Use it to see what changed in the app and why: git log --stat <from>..<to>, then git diff <from> <to> -- <path> for the paths that matter, as a developer reviewing the changes would. Read the files themselves in the read-only copies.
    TEXT
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

    # The feature the turn is for: the one its turn was started for (even
    # once a Stop failed it, so that it keeps to its own branch: final review
    # C2), else the one the run is building, if any.
    def feature
      return @feature if defined?(@feature)

      @feature = setup.features.find_by(design_turn_id: DesignTurn.where(chat_session_id: @session.id).select(:id)) ||
                 setup.features.find_by(status: "running")
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

    # The designs folder a context's screens go in.
    def self.folder_for(role) = role.name.parameterize.presence || "context-#{role.position.to_i + 1}"

    # A resync's look at what changed: code and history only.
    def code_only? = setup.phase == "resync"

    # A context without a login, or one that could not sign in this time
    # (no state of its own now), is built from the code (Kacper, 2026-11-22).
    CODE_CONTEXTS_NOTE = <<~TEXT.freeze
      # Contexts built from the code

      A context with no browser is built from the app's code: its routes, permissions, navigation, views and components, with fake data of the kind its views show. Say in a <missing> note that its screens were built from the code and not checked against the app.
    TEXT

    def browser?(role) = role.signs_in? && setup.run_dir.join("auth", "#{Designs::SignIn.slug(role)}.json").file?

    # Every line names the context's slug, which the map's features and the
    # saved features name contexts by (final review I4).
    def context_line(role)
      folder = "designs/#{self.class.folder_for(role)}/"
      slug = Designs::SignIn.slug(role)
      return "#{role.name} (#{slug}): #{folder}#{' (no login)' if role.code_only?}" if code_only?
      return "#{role.name}: browser #{slug}, #{folder}" if browser?(role)

      "#{role.name} (#{slug}): no browser (#{role.code_only? ? 'no login' : 'could not sign in'}): build it from the code, #{folder}"
    end

    def from_code_contexts? = !code_only? && project.design_setup_roles.any? { |role| !browser?(role) }

    # The roles the person dismissed before, so that no turn raises them again.
    def dismissed_line
      names = DesignImportSuggestion.dismissed_contexts(project)
      "\nRoles the person said not to import: #{names.join(', ')}." if names.any?
    end

    # An import keeps a page's states in its file, as a thread does (Kacper,
    # 2026-11-22): the map lists pages, and a feature's turn builds each page
    # with its states inside.
    PAGES_NOTE = <<~TEXT.freeze
      # Pages, not states

      A screen in the map is a page of the app: its own route or tab. A state of a page (empty, an error, a limit reached, an option off, a dialog open) is part of that page, never a screen of its own, so list the page alone.
    TEXT

    def states_note = "# A screen's states\n\n#{Designs::Prompt::STATES}\n"

    def system_text
      "#{Designs::Prompt.system_text(project: project, composition: composition)}\n#{readable}\n#{code_only? ? CODE_ONLY_NOTE : BROWSER_NOTE}" \
        "#{"\n#{GIT_NOTE}" if history?}" \
        "\n#{SUGGEST_NOTE}" \
        "#{"\n#{CODE_CONTEXTS_NOTE}" if from_code_contexts?}" \
        "#{"\n#{PAGES_NOTE}" if setup.phase.in?(%w[map resync])}" \
        "#{"\n#{states_note}" if setup.phase == 'feature'}" \
        "#{"\n#{BLOCKED_NOTE}" if setup.phase == 'feature' && !setup.reimport?}"
    end

    def forbidden_texts = composition.texts
    def library_version_ids = composition.version_ids

    # The stack, the app's repositories and the contexts, by the slugs the
    # browser knows them by, come with every setup turn; the request is last.
    def turn_message(request, **)
      ui = Workshop::DesignsModuleController::UI_SYSTEMS.fetch(project.designs_ui_system, project.designs_ui_system.to_s.humanize)
      repos = Array(project.design_app_repos).filter_map { |row| "#{row['role']}: #{row['repo']}" if row.is_a?(Hash) }
      contexts = project.design_setup_roles.map { |role| context_line(role) }
      <<~MESSAGE
        ## Setup run
        This turn: #{PHASE_TITLES.fetch(setup.phase, setup.phase.humanize.downcase)}

        ## Stack
        #{Workshop::DesignsModuleController::TECHNOLOGY} with #{[ ui, project.designs_ui_version ].compact_blank.join(' ')}

        ## App repositories
        #{repos.join("\n").presence || "(the project's own repository)"}

        ## Contexts
        #{contexts.join("\n").presence || "(none)"}#{dismissed_line}

        ## Request
        #{request.to_s.strip}
      MESSAGE
    end

    def tools
      Designs::TurnJob::TOOLS + (code_only? ? [] : BROWSER_TOOLS) + (SAVING.include?(setup.phase) ? MAP_TOOLS : []) + [ SUGGEST_TOOL ] +
        (history? ? [ GIT_TOOL ] : [])
    end
    # The CLI's own set of tools, beside the browser's.
    def tool_set = nil
    def timeout = DesignTurn.setup_timeout
    def budget_usd = DesignTurn.setup_budget_usd
    # The app comes from the repositories the run cloned (add_dirs).
    def app_copy? = false

    # The turn's browser: its config written beside the run's states (no
    # password is in it), and the CLI's MCP config in the system's temp folder,
    # gone when the turn is done. A killed turn's is swept with its prompt's.
    def with_mcp(worktree, **)
      FileUtils.mkdir_p(setup.run_dir)
      File.chmod(0o700, setup.run_dir)
      config = setup.run_dir.join("browser.json")
      File.write(config, JSON.generate(browser_config(worktree)), perm: 0o600)
      server = { command: "node", args: [ File.join(Designs::SignIn.crawler_dir, "browser.mjs") ],
                 env: Designs::SignIn.node_env.merge("FLOSIS_BROWSER_CONFIG" => config.to_s) }
      servers = { flosis_browser: server }
      if history?
        servers[:flosis_git] = { command: "node", args: [ File.join(Designs::SignIn.crawler_dir, "git.mjs") ],
                                 env: Designs::SignIn.node_env.merge("FLOSIS_GIT_REPOS" => JSON.generate(clones)) }
      end
      Tempfile.create([ "#{Designs::TurnJob::PROMPT_PREFIX}-mcp", ".json" ]) do |file|
        file.write(JSON.generate(mcpServers: servers))
        file.close
        yield file.path
      end
    end

    # The project's own key, as its turns use; Flosis's setup key for a
    # project that has none; with neither, the server's Claude login.
    def api_key = ProjectCredentials.new(project).designs_api_key || ENV["FLOSIS_DESIGNS_SETUP_API_KEY"].presence

    # The app's repositories the run cloned and the materials, all read-only.
    def add_dirs
      [ *Designs::AppRepos.new(setup).dirs, materials_dir.to_s ].select { |dir| File.directory?(dir) }
    end

    # The app's history clones the git tool reads, { "owner/name" => path }.
    def clones = @clones ||= Designs::AppHistory.new(project).clones
    def history? = clones.any?

    # Every credential of the project, and every role's password.
    def secrets
      (ProjectCredentials.new(project).all_secrets + project.design_setup_roles.map(&:password)).compact.uniq
    end

    # A re-import shows its Changes against its thread's base.
    def publish_base = setup.design_thread&.base_sha.presence
    def publish_page = nil
    def chips(*, **) = []
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
        featureKey: feature&.key, viewport: VIEWPORT, suggestionsPath: setup.run_dir.join("suggestions.jsonl").to_s }
    end

    def readable
      lines = []
      Designs::AppRepos.new(setup).dirs.each { |dir| lines << "- The app's code: #{dir}" }
      lines << "- Materials the team uploaded: #{materials_dir}" if project.design_materials.attached?
      Array(project.design_figma_urls).each { |url| lines << "- Figma: #{url}" }
      return "" if lines.empty?

      "\n# What you can read for this run (read-only)\n\n#{lines.join("\n")}\n"
    end
  end
end
