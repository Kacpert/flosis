# Starts a project's design repo and publishes its master: the empty GitHub
# repository gets the template (Designs::Template) as its first commit on
# master, made as Flosis through the leak guard, pushed, and then published to
# the preview host. A repo that already has master is only published again, so
# running the job twice is harmless.
#
# design_repo_status follows the run: "initializing", then "ready", or "error"
# with design_repo_error saying what went wrong. A git failure arrives from
# GitRunner with the token already filtered out of its message.
#
# Everything runs under the repo's lock, so a publish or a turn on the same
# project never meets it in git's own files.
class Designs::InitializeRepoJob < ApplicationJob
  queue_as :default

  COMMIT_MESSAGE = "Start the design repo".freeze

  # design_repo_error is read by the people using the project, and the
  # message of a refused repo can list every branch it has.
  ERROR_LIMIT = 500

  # The leak guard refused the template. It named paths and rules only, and
  # nothing of the refused commit was kept.
  class Refused < StandardError; end

  def perform(project_id)
    project = Project.find_by(id: project_id)
    return unless project&.designs_enabled? && ProjectCredentials.new(project).design_repo_configured?

    repo = Designs::Repo.new(project)
    repo.synchronize do
      project.update_columns(design_repo_status: "initializing", design_repo_error: nil)
      repo.ensure_clone!
      start_master(project, repo) unless repo.initialized?
      Designs::Publisher.new(project, repo).publish!(Designs::Repo::MASTER, "master")
      project.update_columns(design_repo_status: "ready", design_repo_error: nil)
    end
  rescue => e
    Rails.logger.error("[#{self.class.name}] project #{project_id}: #{e.class}: #{e.message}")
    project&.update_columns(design_repo_status: "error", design_repo_error: e.message.to_s.scrub.first(ERROR_LIMIT))
  end

  private

  # master's first commit, then the push. The commit can come back empty and the
  # push must still happen: an earlier run may have committed the same template
  # and failed to push it, and then there is nothing new to commit.
  def start_master(project, repo)
    Designs::Template.render_into(repo.root, project: project)
    result = Designs::Committer.new(repo, Designs::LeakGuard.new(secrets: stored_secrets(project)))
                               .commit!(repo.root, message: COMMIT_MESSAGE)
    raise Refused, refusal_message(result.violations) unless result.ok?

    repo.push!(Designs::Repo::MASTER)
  end

  # Every credential Flosis stores on the project, from its own columns: the
  # secrets are the encrypted ones, so a credential added to the model is
  # guarded without anyone remembering this job. ProjectCredentials is not
  # asked, because it falls back to the machine's own keys.
  def stored_secrets(project)
    Project.encrypted_attributes.map { |attribute| project.public_send(attribute) }.compact_blank
  end

  # A violation names its path and rule, never the text, so this repeats nothing
  # that was refused.
  def refusal_message(violations)
    "The design repo's first commit was refused: " \
      "#{violations.map { |violation| "#{violation.path} #{violation.reason}" }.join("; ")}."
  end
end
