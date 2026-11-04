# The Designs setup, feature by feature, unattended: from the setup form to
# master in the six steps of DesignSetup::STEPS. It reads the app's
# repositories (making the designs repo if it is new), signs in to the test
# environment as each context, has Claude map the app's features and build
# the design system, then builds the features one after another (each a
# setup turn of its own, which uses the app in a browser, writes the
# feature's screens and checks them against it) and lands it all on master,
# recorded as the import's merge.
#
# One execution runs one unit, a step or one feature, and enqueues the next,
# so a deploy that kills the worker costs that unit at most. A unit is claimed
# until a deadline (DesignSetup#claim_unit!) that a heartbeat moves on while
# the unit runs: the job delivered again after a restart takes its unit over
# at once, and a run whose job is gone is found stalled once the heartbeat has
# stopped for UNIT_GRACE, and picked up again (Designs::ResumeSetupsJob).
# Whoever takes a unit over first stops what the killed attempt left: its
# turn, and its Claude, which a killed worker does not take with it.
#
# What the run cannot go past stops it, failed with its error: no designs
# repository, no app repository read, nobody signed in, an empty map, a step's
# turn that failed. "Retry" goes on from that step. A feature whose turn fails
# is marked and noted, and the run goes on. A re-import runs on its own thread
# and stops short of master: the thread is merged like any other.
#
# After an import is over (Designs imports), the job also builds what is
# queued on it: features retried, answered or added from its page, one a unit
# in the order they were asked for, each on a branch of its own off master
# (Designs::BranchNames.import), landing on master by itself as it finishes
# (Designs::ImportLanding). The import settles when its queue is empty. Only
# one import unit runs on the server at a time: a job that finds another
# import's unit live waits its turn. A turn that Claude's session limit stops
# pauses the run until the limit resets (its feature to do again, and nothing
# after it tried meanwhile), and the job comes back then; an answer the CLI
# could not read is tried twice more before its feature couldn't finish.
class Designs::SetupRunJob < ApplicationJob
  queue_as :designs

  class Failure < StandardError; end

  # Claude's session limit ran out: the run waits until it resets.
  class Paused < StandardError
    attr_reader :until_time

    def initialize(until_time)
      @until_time = until_time
      super("paused until #{until_time}")
    end
  end

  STOPS = [ Failure, Designs::AppRepos::Failure, Designs::SignIn::Failure ].freeze
  # How long a unit's claim lasts without a heartbeat.
  UNIT_GRACE = 15.minutes
  # How long a job waits while another import's unit runs on the server.
  WAIT_TURN = 2.minutes
  # How many more times a feature whose answer could not be read is tried.
  UNREADABLE_RETRIES = 2
  MAP_REQUEST = "Map the app's features, in the order they are to be built, and save the map.".freeze
  DESIGN_SYSTEM_REQUEST = "Build the design system: the tokens, fonts, icons and logos, from the app's code and its pages.".freeze
  RESYNC_REQUEST = "Find what changed in the app since the last import: the features of the map the changes touch, and the features " \
                   "that are new. Save them with save_features, once, at the end.".freeze
  IMPORT_SUMMARY = "Initial import: the design system, the components and the screens of every feature, " \
                   "built from the test environment and the app's repositories.".freeze

  class << self
    # What runs a setup turn, signs the contexts in, reads the app's
    # repositories and stops a Claude a killed worker left (by its session
    # id, which only its command line carries), here and now; and how often
    # the heartbeat beats, in seconds. Tests stand in for them.
    attr_writer :turn_runner, :sign_in, :app_repos, :killer, :heartbeat_every, :app_changes

    def turn_runner = @turn_runner || ->(turn_id) { Designs::TurnJob.perform_now(turn_id) }
    def sign_in = @sign_in || ->(setup) { Designs::SignIn.new(setup).call }
    def app_repos = @app_repos || ->(setup) { Designs::AppRepos.new(setup).fetch! }
    def app_changes = @app_changes || ->(setup) { Designs::AppChanges.new(setup).fetch! }
    def killer = @killer || ->(session_id) { system("pkill", "-TERM", "-f", session_id, out: File::NULL, err: File::NULL) }
    def heartbeat_every = @heartbeat_every || 300

    # Stops what an earlier attempt at the run left: its setup turns (and the
    # turns that bring an accepted proposal up to date) still marked running
    # or queued, whose jobs are gone (whoever calls this holds the run's
    # unit), and the Claude each may still be running. Another import's turns
    # are left alone; a session from before sessions knew their import counts
    # for every import of its project.
    def stop_attempts!(setup)
      DesignTurn.joins(:chat_session).includes(:chat_session).where(kind: %w[setup resolve_conflicts], status: DesignTurn::ACTIVE)
                .where(chat_sessions: { project_id: setup.project_id, purpose: "designs_setup" })
                .where("chat_sessions.design_setup_id = ? OR chat_sessions.design_setup_id IS NULL", setup.id).find_each do |turn|
        killer.call(turn.chat_session.claude_session_id)
        turn.fail!(DesignTurn::INTERRUPTED)
      end
    end
  end

  def perform(setup_id)
    setup = DesignSetup.find_by(id: setup_id)
    return unless setup && (setup.running? || setup.follow_up?)
    return wait_turn(setup) if another_import_runs?(setup)
    return unless setup.claim_unit!(job_id, limit: UNIT_GRACE)

    # Work queued after the import is over: what goes wrong is that
    # feature's, never the import's, which master already has.
    @follow_up = !setup.running?
    self.class.stop_attempts!(setup)
    setup.update!(paused_until: nil) if setup.paused_until
    heartbeat = beat(setup)
    if setup.running?
      setup.start_step!
      send(setup.step_names.fetch(setup.step), setup)
    else
      follow_up(setup)
    end
    heartbeat.kill
    setup.release_unit!(job_id)
    go_on(setup.reload)
  rescue Paused => e
    pause(setup, e.until_time)
  rescue *STOPS => e
    @follow_up ? give_up_feature(setup, trouble(e)) : stop(setup, e.message)
  rescue StandardError => e
    Rails.logger.error("[#{self.class.name}] setup #{setup_id}: #{e.class}: #{e.message}")
    @follow_up ? give_up_feature(setup, trouble(e)) : stop(setup, "#{e.class.name}: #{e.message}")
  ensure
    heartbeat&.kill
  end

  private

  # A feature queued after the import, which something outside its turn
  # stopped (a sign-in, a push GitHub refused, the host): it couldn't finish,
  # and the queue goes on.
  def give_up_feature(setup, message)
    return unless setup

    ours = setup.with_lock do
      next false if setup.unit_job_id.present? && setup.unit_job_id != job_id

      setup.features.where(status: "running").find_each do |feature|
        feature.update!(status: "failed", stage: nil, finished_at: Time.current, error: message.to_s.truncate(1_000))
      end
      setup.update!(unit_job_id: nil, unit_deadline_at: 1.second.ago)
      true
    end
    go_on(setup.reload) if ours
  end

  # What stopped a feature, in plain words.
  def trouble(error)
    case error
    when Designs::SignIn::Failure then "Couldn't sign in: #{error.message}"
    when Designs::AppRepos::Failure then "Couldn't read the app: #{error.message}"
    when Failure then error.message
    else "#{error.class.name}: #{error.message}"
    end
  end

  # The next unit, or, for an import whose queue is empty, its settling.
  def go_on(setup)
    if setup.running? || setup.follow_up?
      self.class.perform_later(setup.id)
    elsif setup.done? && setup.features.where("queued_at > ?", setup.settled_at || setup.finished_at || setup.created_at).exists?
      setup.settle!
    end
  end

  # Another import's unit holds the server: Chromium, Claude and the MCP
  # browser take most of the threads the host allows (Designs imports).
  def another_import_runs?(setup)
    DesignSetup.unit_running?(except: setup.id)
  end

  # The job comes back later. Meanwhile the run's deadline is kept ahead, so
  # that the resume job does not take it for stalled and queue it again.
  def wait_turn(setup)
    setup.with_lock { setup.update!(unit_deadline_at: UNIT_GRACE.from_now) if setup.unit_job_id.nil? }
    self.class.set(wait: WAIT_TURN).perform_later(setup.id)
  end

  # The run waits for Claude's limit to reset: its unit is let go, with the
  # deadline past the reset, so the resume job leaves it alone meanwhile, and
  # its job comes back then.
  def pause(setup, until_time)
    paused = setup.with_lock do
      next false if setup.unit_job_id.present? && setup.unit_job_id != job_id

      setup.update!(paused_until: until_time, unit_job_id: nil, unit_deadline_at: until_time + UNIT_GRACE)
      true
    end
    self.class.set(wait_until: until_time).perform_later(setup.id) if paused
  end

  # Why a turn failed, when it is a reason to wait rather than fail: Claude's
  # session limit, with when it resets.
  def limit!(turn)
    raise Paused, Designs::UsageLimit.reset_at(turn.error) if Designs::UsageLimit.hit?(turn.error)
  end

  # A run stops only by the job that holds its unit: one that lost it (its
  # run was picked up again) leaves the run to the job that has it.
  def stop(setup, message)
    return unless setup

    setup.with_lock do
      next if setup.unit_job_id.present? && setup.unit_job_id != job_id
      next if setup.done?

      setup.update!(status: "failed", error: message.to_s.truncate(1_000), unit_job_id: nil, unit_deadline_at: nil)
    end
  end

  # Keeps the unit's claim alive while it runs. A job killed with its worker
  # stops beating, and its run is found stalled UNIT_GRACE later.
  def beat(setup)
    id = setup.id
    job = job_id
    every = self.class.heartbeat_every
    Thread.new do
      loop do
        sleep every
        ActiveRecord::Base.connection_pool.with_connection do
          DesignSetup.where(id: id, unit_job_id: job).update_all(unit_deadline_at: UNIT_GRACE.from_now)
        end
      end
    rescue StandardError => e
      Rails.logger.warn("[#{self.class.name}] setup #{id}: the heartbeat stopped: #{e.class}: #{e.message}")
    end
  end

  def read_repos(setup)
    project = setup.project
    unless project.design_repo_status == "ready"
      Designs::InitializeRepoJob.perform_now(project.id)
      project.reload
      raise Failure, project.design_repo_error.presence || "The designs repository could not be set up." unless project.design_repo_status == "ready"
    end
    fetched = self.class.app_repos.call(setup)
    setup.finish_step!(app_commits: Array(fetched).map { |row| row.slice("repo", "branch", "sha") })
  end

  def sign_in(setup)
    self.class.sign_in.call(setup)
    setup.finish_step!
  end

  # The map: a turn that walks the app and saves its features, read into the
  # run's features in the map's order. A map run again replaces them.
  def map_features(setup)
    FileUtils.mkdir_p(setup.run_dir)
    File.chmod(0o700, setup.run_dir)
    map = setup.run_dir.join("features.json")
    FileUtils.rm_f(map)
    self.class.sign_in.call(setup)
    setup.update!(phase: "map")
    run_turn!(setup, MAP_REQUEST)
    rows = saved_features(map)
    raise Failure, "The map found no features." if rows.empty?

    setup.features.destroy_all
    setup.add_features!(rows)
    setup.finish_step!
  end

  # The rows the map's (or a resync's) save_features wrote, [] for none.
  def saved_features(file)
    Array(JSON.parse(file.read)).select { |row| row.is_a?(Hash) }
  rescue JSON::ParserError, SystemCallError
    []
  end

  # A resync's look at what changed (Designs imports): the app's diffs since
  # the import it starts from, and a turn that reads them with the map, walks
  # the app and saves the features the changes touch and the new ones. Those
  # become the resync's features. Nothing changed: nothing to build.
  def find_changes(setup)
    FileUtils.mkdir_p(setup.run_dir)
    File.chmod(0o700, setup.run_dir)
    changed = self.class.app_changes.call(setup).select { |row| row["path"] }
    if changed.empty?
      setup.note!("Finding what changed", "Nothing changed in the app's repositories since #{setup.since_label}.")
      return setup.finish_step!
    end

    map = setup.run_dir.join("features.json")
    FileUtils.rm_f(map)
    self.class.sign_in.call(setup)
    setup.update!(phase: "resync")
    run_turn!(setup, resync_request(setup, changed))
    add_resync_features!(setup, saved_features(map))
    setup.finish_step!
  end

  def resync_request(setup, changed)
    map = setup.project.design_feature_map.map do |feature|
      "- #{feature.key} · #{feature.name} · contexts: #{feature.contexts.join(', ').presence || 'every context'} · " \
        "screens: #{feature.screens.join(', ').presence || 'as its brief says'}\n  #{feature.brief.to_s.squish.truncate(300)}"
    end
    diffs = changed.map do |row|
      "- #{row['repo']}#{" @ #{row['branch']}" if row['branch']}: #{row['from'].to_s.first(7)}..#{row['to'].to_s.first(7)}, the diff in #{row['path']}"
    end
    "#{RESYNC_REQUEST}\n\n## The map\n#{map.join("\n").presence || '(no features yet)'}\n\n" \
      "## What changed in the app since #{setup.since_label}\n#{diffs.join("\n")}"
  end

  # A feature the changes touch is the map's, with what changed in its code;
  # one the map lacks is new. A proposal of an earlier import still waiting
  # for the same feature is replaced by this one.
  def add_resync_features!(setup, rows)
    known = setup.project.design_feature_map.index_by(&:key)
    taken = known.keys + setup.features.pluck(:key)
    position = setup.features.maximum(:position).to_i
    rows.each do |row|
      existing = known[row["key"].to_s]
      attributes = if existing
                     { key: existing.key, name: existing.name, source: "changed", brief: existing.brief,
                       contexts: Array(row["contexts"]).map(&:to_s).presence || existing.contexts,
                       screens: Array(row["screens"]).map(&:to_s).presence || existing.screens }
                   else
                     name = row["name"].to_s.strip.presence || "Feature"
                     { key: DesignSetupFeature.key_for(name, taken), name: name.truncate(120), source: "new", brief: row["brief"].to_s,
                       contexts: Array(row["contexts"]).map(&:to_s), screens: Array(row["screens"]).map(&:to_s) }
                   end
      next if setup.features.exists?(key: attributes[:key])

      taken << attributes[:key]
      feature = setup.features.create!(attributes.merge(position: position += 1, status: "todo", queued_at: Time.current,
                                                        code_changes: row["changes"].to_s.strip.presence, notes: Array(row["notes"]).map(&:to_s)))
      replace_older_proposals!(feature)
    end
    setup.features.reset
  end

  def replace_older_proposals!(feature)
    setup = feature.design_setup
    DesignSetupFeature.joins(:design_setup).where(design_setups: { project_id: setup.project_id }).where.not(design_setup_id: setup.id)
                      .where(key: feature.key, status: "review").find_each do |older|
      Designs::ImportLanding.new(older).discard!
      older.update!(status: "set_aside", branch: nil, review: older.review.merge("rejected" => "Replaced by “#{setup.title}”"))
    end
  end

  def design_system(setup)
    self.class.sign_in.call(setup)
    setup.update!(phase: "design_system")
    run_turn!(setup, DESIGN_SYSTEM_REQUEST)
    setup.finish_step!
  end

  # One feature a unit, the first not finished: it signs in afresh, is built
  # by a turn of its own, and is done (with what it did to the components and
  # the turn's notes) or failed (noted, and the run goes on). With none left,
  # the step is over.
  def features(setup)
    return resync_features(setup) if setup.resync?

    feature = setup.features.pending.first
    return setup.finish_step! unless feature

    self.class.sign_in.call(setup)
    feature.update!(status: "running", stage: "building", started_at: feature.started_at || Time.current, error: nil, resets_at: nil)
    FileUtils.rm_f(setup.run_dir.join("progress.json"))
    setup.update!(phase: "feature")
    repo = Designs::Repo.new(setup.project)
    before = repo.head(feature.branch.presence || branch(setup))
    turn = start_turn(setup, follow_up_request(feature))
    feature.update!(design_turn: turn)
    self.class.turn_runner.call(turn.id)
    finish_feature(feature, turn.reload, repo, before)
  end

  # A feature of the import itself, as its turn left it. One that went on
  # from its own branch (the person answered the AI's question while the
  # import still ran) joins wip/setup, to land with the rest.
  def finish_feature(feature, turn, repo, before)
    if turn.succeeded?
      question = question_in(turn)
      return wait_for_answer(feature, turn, repo, before, question) if question

      counts = Designs::ComponentCount.between(repo, before, turn.commit_sha || repo.head(feature.branch.presence || branch(feature.design_setup)))
      join_import!(feature, repo) if feature.branch.present?
      feature.update!(status: "done", stage: nil, finished_at: Time.current, components_new: counts[:new],
                      components_reused: counts[:reused], notes: feature.notes + missing_in(turn), branch: nil)
    elsif Designs::UsageLimit.hit?(turn.error)
      resets = Designs::UsageLimit.reset_at(turn.error)
      feature.update!(status: "todo", stage: nil, error: turn.error, resets_at: resets, finished_at: Time.current)
      raise Paused, resets
    elsif DesignSetupFeature::UNREADABLE.match?(turn.error.to_s) && feature.attempts < UNREADABLE_RETRIES
      feature.update!(status: "todo", stage: nil, error: turn.error, attempts: feature.attempts + 1)
    else
      error = turn.error.presence || "Claude could not finish this feature."
      feature.update!(status: "failed", stage: nil, finished_at: Time.current, error: error,
                      notes: feature.notes + [ "Could not finish: #{error}".truncate(500) ])
    end
  rescue Designs::Repo::Conflict => e
    feature.update!(status: "failed", stage: nil, finished_at: Time.current, error: "Couldn't join the import: #{e.message}".truncate(500))
  end

  # The AI's question for the person, when it stopped the feature on what
  # only they can fix.
  def question_in(turn)
    turn.chat_session.chat_messages.where(kind: "blocked").where("id > ?", turn.chat_message_id).order(:id).last&.content.presence
  end

  def missing_in(turn)
    turn.chat_session.chat_messages.where(kind: "missing").where("id > ?", turn.chat_message_id).order(:id).pluck(:content)
  end

  # The feature waits for the person's answer, and the run goes on. What it
  # built so far stays on a branch of its own: taken off wip/setup (or a
  # re-import's thread) when it was built there, so that nothing half-built
  # lands with the import.
  def wait_for_answer(feature, turn, repo, before, question)
    shared = branch(feature.design_setup)
    # A branch this very turn began starts where master was.
    start = before || repo.merge_base(shared, Designs::Repo::MASTER)
    if feature.branch.blank? && start && turn.commit_sha && turn.commit_sha != start
      own = Designs::BranchNames.import(feature)
      repo.synchronize do
        repo.point!(own, to: turn.commit_sha)
        repo.rewind!(shared, to: start)
        repo.push!("refs/heads/#{own}", "+refs/heads/#{shared}")
      end
      feature.branch = own
    end
    feature.update!(status: "waiting", stage: nil, finished_at: Time.current, question: question, notes: feature.notes + missing_in(turn))
  end

  # A feature that went on from its own branch during the import joins the
  # import's branch, and its own goes, here and on GitHub.
  def join_import!(feature, repo)
    setup = feature.design_setup
    target = branch(setup)
    repo.synchronize do
      dir = repo.worktree!(target, from: setup.design_thread&.base_sha.presence || Designs::Repo::MASTER)
      repo.merge_branch_into!(dir, feature.branch, message: "#{feature.name}: built after the person's answer")
      repo.push!(target, *(":refs/heads/#{feature.branch}" if repo.remote_head(feature.branch)))
      path = repo.worktree_path(feature.branch)
      repo.remove_worktree!(path) if path.exist?
      repo.delete_branch!(feature.branch) if repo.head(feature.branch)
    end
  end

  # A resync's features are each built on a branch of their own off master
  # and land there as they finish, as features queued after an import do.
  def resync_features(setup)
    return setup.finish_step! unless setup.features.pending.exists?

    follow_up(setup)
  end

  # A resync is over once its features have landed, one by one.
  def finish(setup)
    setup.finish_step!(status: "approved", finished_at: Time.current, settled_at: Time.current)
  end

  def commit(setup)
    if (thread = setup.design_thread)
      Designs::Threads.note(thread, "Re-import from staging finished. Check what changed, then merge it.")
    else
      project = setup.project
      Designs::SetupApproval.new(project, user: setup.started_by, wait: true).approve!
      master = Designs::Repo.new(project).head(Designs::Repo::MASTER)
      project.design_merges.create!(sha: master, title: "Initial import from staging", branch: "setup", how: "setup",
                                    screens: [], commits: 1, summary: IMPORT_SUMMARY,
                                    what_changed: [ "Design system: tokens, type scale and spacing", "Components",
                                                    "#{setup.features.where(status: 'done').size} features, every context" ],
                                    merged_at: Time.current)
    end
    setup.finish_step!(status: "approved", finished_at: Time.current, settled_at: Time.current)
  end

  # One feature queued on an import that is over: the first queued, on its
  # branch (a fresh one off master, unless it goes on from where it stopped),
  # built by a turn of its own and landed on master by itself. A feature a
  # killed attempt left running is queued again first, on the same branch.
  def follow_up(setup)
    setup.features.where(status: "running").find_each { |feature| feature.update!(status: "todo") }
    feature = setup.features.where(status: "todo").reorder(:queued_at, :position).first or return

    feature.update!(status: "running", stage: "building", started_at: Time.current, error: nil, resets_at: nil)
    self.class.sign_in.call(setup)
    self.class.app_repos.call(setup) if Designs::AppRepos.new(setup).dirs.empty?
    repo = Designs::Repo.new(setup.project)
    branch = feature.branch.presence || fresh_branch!(repo, feature)
    feature.update!(branch: branch)
    FileUtils.rm_f(setup.run_dir.join("progress.json"))
    setup.update!(phase: "feature")
    before = repo.head(branch)
    # An accepted proposal master moved under is brought up to date first.
    kind = feature.review["accepted"] ? "resolve_conflicts" : "setup"
    turn = start_turn(setup, follow_up_request(feature), kind: kind)
    feature.update!(design_turn: turn)
    self.class.turn_runner.call(turn.id)
    finish_follow_up(feature, turn.reload, repo, before)
  end

  # A branch off master for the feature, made afresh: one an earlier attempt
  # left goes, here and on GitHub.
  def fresh_branch!(repo, feature)
    name = Designs::BranchNames.import(feature)
    repo.synchronize do
      repo.ensure_clone!
      path = repo.worktree_path(name)
      repo.remove_worktree!(path) if path.exist?
      repo.delete_branch!(name) if repo.head(name)
      repo.push!(":refs/heads/#{name}") if repo.remote_head(name)
      repo.worktree!(name, from: Designs::Repo::MASTER)
    end
    name
  end

  # The feature's brief, with what threads put on master since the import
  # (for a feature built after it), and what the person said: an answer to
  # the AI's question, words about its proposal, or words to start with.
  def follow_up_request(feature)
    said = if feature.reply && feature.question
             "## You asked\n#{feature.question}\n\n## They replied\n#{feature.reply}\n\n" \
               "Check what they said (sign in again, look again) and go on from where you stopped: what you built so far is on this branch."
           elsif feature.reply && feature.review.key?("comes_in")
             "## What they said about your proposal\n#{feature.reply}\n\n" \
               "Your proposal is on this branch: change it as they say, then say again what comes in, what is kept and what is replaced."
           elsif feature.reply
             "## Before you start\n#{feature.reply}"
           end
    setup = feature.design_setup
    [ Designs::FeatureBrief.for(feature), (threads_on_master(setup) unless setup.first? && setup.running?), said ].compact.join("\n")
  end

  # The designs threads merged into master, for an update not to throw them
  # away: what it brings in, keeps and replaces is said in blocks of its own.
  def threads_on_master(setup)
    merges = setup.project.design_merges.where(how: %w[manual auto]).newest_first.limit(10).to_a
    return if merges.empty?

    lines = merges.map { |merge| "- “#{merge.title}”, merged #{merge.merged_at.to_date}: #{Array(merge.screens).first(6).join(', ').presence || 'its screens'}" }
    "## Work from threads on master\n#{lines.join("\n")}\n\n" \
      "These were designed in threads and may not be built in the app yet. Keep them, unless the app has the same thing built differently. " \
      "Say what your work brings in, one <comes-in> block an item; what of the threads' work you keep, one <kept> block each; " \
      "and what you replace, one <replaced> block each."
  end

  def finish_follow_up(feature, turn, repo, before)
    return finish_feature(feature, turn, repo, before) unless turn.succeeded?

    question = question_in(turn)
    return wait_for_answer(feature, turn, repo, before, question) if question

    counts = Designs::ComponentCount.between(repo, before, turn.commit_sha || repo.head(feature.branch))
    notes = missing_in(turn)
    feature.update!(components_new: counts[:new], components_reused: counts[:reused], notes: feature.notes + notes)
    Designs::ImportLanding.new(feature).land!(accepted: feature.review["accepted"].present?)
    feature.update!(status: "done", stage: nil, finished_at: Time.current, branch: nil)
  rescue Designs::ImportLanding::NeedsReview => e
    review!(feature, turn, e.touched)
  rescue Designs::Repo::Conflict
    feature.update!(status: "failed", stage: nil, finished_at: Time.current, error: Designs::ImportLanding::CONFLICT)
  rescue Designs::ImportLanding::NotLanded => e
    feature.update!(status: "failed", stage: nil, finished_at: Time.current, error: e.message)
  end

  # The update waits for the person: what it brings in, keeps and replaces, as
  # the AI said, and the threads whose work it would replace. An AI that said
  # nothing still leaves the files it would change on the card.
  def review!(feature, turn, touched)
    said = turn.chat_session.chat_messages.where("id > ?", turn.chat_message_id).order(:id)
    lists = %w[comes_in kept replaced].index_with { |kind| said.where(kind: kind).pluck(:content) }
    paths = touched.map { |item| item[:path] }.uniq
    lists["replaced"] = paths.map { |path| "What threads made in #{path}" } if lists.values.all?(&:empty?)
    feature.update!(status: "review", stage: nil, finished_at: Time.current,
                    review: lists.merge("threads" => touched.filter_map { |item| item[:merge]&.title }.uniq, "paths" => paths))
  end

  # A setup turn, run here and now: the run waits for it, and a step's turn
  # that fails stops the run.
  def run_turn!(setup, request)
    turn = start_turn(setup, request)
    self.class.turn_runner.call(turn.id)
    turn.reload
    limit!(turn) unless turn.succeeded?
    raise Failure, turn.error.presence || "Claude could not finish this step." unless turn.succeeded?

    turn
  end

  # Each unit is a Claude session of its own: a feature starts afresh, from
  # the repository, never from the last feature's conversation.
  def start_turn(setup, request, kind: "setup")
    project = setup.project
    session = ChatSession.create!(project: project, workspace: project.workspace, user: setup.started_by, purpose: "designs_setup",
                                  claude_session_id: SecureRandom.uuid, codebase_path: project.designs_dir.to_s, design_setup: setup)
    message = session.chat_messages.create!(role: "user", user: setup.started_by, content: request)
    DesignTurn.create!(chat_session: session, chat_message: message, kind: kind)
  end

  def branch(setup) = setup.design_thread&.branch || Designs::BranchNames::SETUP
end
