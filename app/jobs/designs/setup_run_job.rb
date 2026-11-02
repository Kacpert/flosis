# The Designs setup, unattended (Workshop Designs v2): from the setup form to
# master, in the seven steps Kacper's design lists. It reads the repositories
# (making the designs repo if it is new), signs in to staging as each context
# and captures what each sees (Designs::CrawlJob), has Claude build the design
# system, the components and the screens (three setup turns, as v1's setup run
# phases), and commits it all to master, recorded as the import's merge.
#
# A failed step stops the run where it is: "Retry" starts it again from that
# step. A re-import runs on its own thread instead of wip/setup, and stops
# short of master: the thread is merged like any other.
class Designs::SetupRunJob < ApplicationJob
  queue_as :designs

  class Failure < StandardError; end

  STEPS = %i[read_repos sign_in capture design_system components designs commit].freeze
  PHASE_REQUESTS = {
    "design_system" => "Recreate the design system: tokens, type, spacing and radius, from the app and the captured pages.",
    "components" => "Rebuild the app's components from its code, checked against the captured pages.",
    "designs" => "Recreate today's screens, one folder per context, as each context sees them in the captured pages."
  }.freeze
  IMPORT_SUMMARY = "Initial import: design system, components and current screens captured from staging and the app repositories.".freeze

  # What runs the crawl and a setup turn, here and now; tests stand in for both.
  class << self
    attr_writer :crawler, :turn_runner

    def crawler = @crawler || ->(setup_id) { Designs::CrawlJob.perform_now(setup_id) }
    def turn_runner = @turn_runner || ->(turn_id) { Designs::TurnJob.perform_now(turn_id) }
  end

  def perform(setup_id)
    setup = DesignSetup.find_by(id: setup_id)
    return unless setup&.status == "active"

    (setup.step...STEPS.size).each do |index|
      setup.update!(step: index, error: nil)
      send(STEPS[index], setup)
    end
    setup.update!(step: STEPS.size, status: "approved", finished_at: Time.current, error: nil)
  rescue Failure => e
    setup&.update!(status: "failed", error: e.message.to_s.truncate(1_000))
  rescue StandardError => e
    Rails.logger.error("[#{self.class.name}] setup #{setup_id}: #{e.class}: #{e.message}")
    setup&.update!(status: "failed", error: "#{e.class.name}: #{e.message}".truncate(1_000))
  end

  private

  def read_repos(setup)
    project = setup.project
    return if project.design_repo_status == "ready"

    Designs::InitializeRepoJob.perform_now(project.id)
    project.reload
    raise Failure, project.design_repo_error.presence || "The designs repository could not be set up." unless project.design_repo_status == "ready"
  end

  def sign_in(setup)
    self.class.crawler.call(setup.id)
    setup.reload
    raise Failure, setup.crawl_error if setup.crawl_error.present?
  end

  def capture(setup)
    summary = setup.crawl_dir && Pathname(setup.crawl_dir).join("crawl.json")
    pages = summary&.file? ? Array(JSON.parse(summary.read)["pages"]).size : 0
    setup.update!(pages: pages)
  rescue JSON::ParserError
    setup.update!(pages: 0)
  end

  def design_system(setup) = phase(setup, "design_system")
  def components(setup) = phase(setup, "components")
  def designs(setup) = phase(setup, "designs")

  # One setup turn, run here and now: the run waits for it.
  def phase(setup, name)
    setup.update!(phase: name)
    project = setup.project
    session = ChatSession.designs_setup_for!(project, user: setup.started_by, codebase_path: project.designs_dir.to_s)
    request = session.chat_messages.create!(role: "user", user: setup.started_by, content: PHASE_REQUESTS.fetch(name))
    turn = DesignTurn.create!(chat_session: session, chat_message: request)
    self.class.turn_runner.call(turn.id)
    turn.reload
    raise Failure, turn.error.presence || "Claude could not finish this step." unless turn.succeeded?
  end

  def commit(setup)
    if (thread = setup.design_thread)
      Designs::Threads.note(thread, "Re-import from staging finished. Check what changed, then merge it.")
      return
    end

    project = setup.project
    Designs::SetupApproval.new(project, user: setup.started_by, wait: true).approve!
    master = Designs::Repo.new(project).head(Designs::Repo::MASTER)
    project.design_merges.create!(sha: master, title: "Initial import from staging", branch: "setup", how: "setup",
                                  screens: [], commits: 1, summary: IMPORT_SUMMARY,
                                  what_changed: [ "Design system: tokens, type scale and spacing", "Components", "Screens across every context" ],
                                  merged_at: Time.current)
  end
end
