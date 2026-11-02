# Starts a project's design repo and publishes its master: the empty GitHub
# repository gets the template (Designs::Template) as its first commit on
# master, made as Flosis through the leak guard, pushed, and then published to
# the preview host. A repo whose master Flosis already started is only
# published again, so running the job twice is harmless; a repo with anything
# else in it is refused (Designs::Repo::NotEmpty).
#
# design_repo_status follows the run: "initializing", then "ready", or "error"
# with design_repo_error saying what went wrong. A git failure arrives from
# GitRunner with the token already filtered out of its message. A status
# describes the repo it was made for, so it is written only while the project
# still points at the repo the run started for (see record).
#
# Everything runs under the repo's lock, so a publish or a turn on the same
# project never meets it in git's own files.
class Designs::InitializeRepoJob < ApplicationJob
  queue_as :default

  # One run per project at a time. Every save that can set the repo up queues
  # a run, and a run waiting for the repo's lock held one of Solid Queue's
  # threads (there are three) while it waited; the others now wait in the
  # queue. The duration only bounds a claim whose run was killed.
  limits_concurrency to: 1, key: ->(project_id) { "designs-init-#{project_id}" }, duration: 1.hour

  COMMIT_MESSAGE = "Start the design repo".freeze

  # design_repo_error is read by the people using the project, and the
  # message of a refused repo can list every branch it has.
  ERROR_LIMIT = 500

  # The leak guard refused the template. It named paths and rules only, and
  # nothing of the refused commit was kept.
  class Refused < StandardError; end

  def perform(project_id)
    project = Project.find_by(id: project_id)
    return unless project

    # The repo this run is for, read once: the Repo below is built for it, and
    # a save that points the project elsewhere must not get this run's status.
    @design_repo = project.design_repo
    unless project.designs_enabled? && ProjectCredentials.new(project).design_repo_configured?
      # The save that queued this run said "initializing"; nothing will run now
      # to say anything else.
      Project.where(id: project.id, design_repo_status: "initializing").update_all(design_repo_status: nil)
      return
    end

    repo = Designs::Repo.new(project)
    repo.synchronize do
      # Pointed elsewhere while the run waited: that repo is not the project's
      # any more, and is left alone.
      next unless record(project, "initializing")

      repo.ensure_clone!
      start_master(project, repo) unless repo.initialized?
      Designs::Publisher.new(project, repo).publish!(Designs::Repo::MASTER, "master")
      record(project, "ready")
    end
  rescue => e
    Rails.logger.error("[#{self.class.name}] project #{project_id}: #{e.class}: #{e.message}")
    record(project, "error", e.message.to_s.scrub.first(ERROR_LIMIT)) if project
  end

  private

  # Writes the status, and whether it could: only while the project still
  # points at the repo this run is for. A save that points it at another repo
  # resets the status for that one, and the run for the old repo, finishing
  # afterwards, must not mark the new one Ready or Failed. One conditional
  # UPDATE, so no save can come between the check and the write.
  def record(project, status, error = nil)
    Project.where(id: project.id, design_repo: @design_repo)
           .update_all(design_repo_status: status, design_repo_error: error).positive?
  end

  # master's first commit, then the push. The commit can come back empty and the
  # push must still happen: an earlier run may have committed the same template
  # and failed to push it, and then there is nothing new to commit.
  def start_master(project, repo)
    Designs::Template.render_into(repo.root, project: project)
    guard = Designs::LeakGuard.new(secrets: ProjectCredentials.new(project).all_secrets, flosis_files: true)
    result = Designs::Committer.new(repo, guard).commit!(repo.root, message: COMMIT_MESSAGE)
    raise Refused, "The design repo's first commit was refused: #{result.refusal}." unless result.ok?

    repo.push!(Designs::Repo::MASTER)
  end
end
