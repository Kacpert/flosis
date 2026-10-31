# What a design turn is for, and what differs with it (Designs::TurnJob runs
# both kinds): a task's turn works on wip/<slug> on the project's own key; a
# setup run's works on wip/setup on Flosis's key, with the phase's prompt and
# the crawl bundle and materials to read. Everything else is the same turn.
#
# A subject composes the library once (Rulings P3-R1, P5-R4): the prompt
# Claude gets, the texts the leak guard refuses and the versions the turn
# records are one read.
module Designs::Subject
  module_function

  def for(chat_session)
    chat_session.purpose == "designs_setup" ? SetupSubject.new(chat_session) : TaskSubject.new(chat_session)
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
    def turn_message(request) = Designs::Prompt.turn_message(task: @task, request: request)
    def api_key = ProjectCredentials.new(project).designs_api_key
    def missing_key_message = Designs::TurnJob::NO_KEY

    # Ruling P5-R1: no folder beyond the per-turn copy of the app.
    def add_dirs = []
    def secrets = ProjectCredentials.new(project).all_secrets
    def prepare! = nil
    def crawling? = false
  end

  class SetupSubject
    NO_KEY = "Flosis's setup key is not configured (FLOSIS_DESIGNS_SETUP_API_KEY).".freeze
    NO_SETUP = "This project has no setup run.".freeze

    def initialize(session)
      @session = session
    end

    def project = @session.project
    def slug = "setup"
    def wip_branch = Designs::BranchNames::SETUP
    def preview_slot = wip_branch
    def base_branch_for_new_worktree = Designs::Repo::MASTER

    # The run's latest active setup.
    def setup
      @setup ||= project.design_setups.active.order(:id).last || raise(Designs::TurnJob::Failure, NO_SETUP)
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
      "#{Designs::Prompt.system_text(project: project, composition: composition)}\n#{readable}"
    end

    def forbidden_texts = composition.texts
    def library_version_ids = composition.version_ids

    def turn_message(request)
      <<~MESSAGE
        ## Setup run
        Phase #{DesignSetup::PHASES.index(setup.phase) + 1} of #{DesignSetup::PHASES.size}: #{setup.phase.humanize.downcase}

        ## Request
        #{request.to_s.strip}
      MESSAGE
    end

    def api_key = ENV["FLOSIS_DESIGNS_SETUP_API_KEY"].presence
    def missing_key_message = NO_KEY

    # Ruling P5-R1/P5-R3: the crawl bundle and the materials, both under the
    # project's designs_dir and read-only; the app comes as the turn's copy.
    def add_dirs
      [ setup.crawl_dir, materials_dir.to_s ].compact.select { |dir| File.directory?(dir) }
    end

    # Every credential of the project, and every role's password.
    def secrets
      (ProjectCredentials.new(project).all_secrets + project.design_setup_roles.map(&:password)).compact.uniq
    end

    def crawling? = setup.crawling?

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

    def readable
      lines = []
      lines << "- The crawl of the running app, one folder per role: #{setup.crawl_dir}" if setup.crawl_dir.present?
      lines << "- Materials the team uploaded: #{materials_dir}" if project.design_materials.attached?
      Array(project.design_figma_urls).each { |url| lines << "- Figma: #{url}" }
      return "" if lines.empty?

      "\n# What you can read for this run (read-only)\n\n#{lines.join("\n")}\n"
    end
  end
end
