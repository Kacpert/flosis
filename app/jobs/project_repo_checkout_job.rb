require "fileutils"

# Clones (or fast-forward pulls) a project's repo into its isolated folder,
# using the resolved GitHub token. Enqueued when the GitHub integration is
# saved (Workshop::ConfigurationController#save_integration). Legacy elvium is
# skipped (it uses the shared ~/work/elvium checkout).
#
# The token reaches git through GitRunner's environment and nowhere else. The
# remote is always the plain https://github.com/<repo>.git, so .git/config
# never holds it.
class ProjectRepoCheckoutJob < ApplicationJob
  queue_as :default

  # Test seam: a lambda ->(args, chdir:, token:) that runs git. The args are
  # git's arguments without the leading "git". Nil in prod.
  class << self
    attr_accessor :stub_git
  end

  def perform(project_id)
    project = Project.find_by(id: project_id)
    return unless project
    return if project.legacy_elvium?

    creds = ProjectCredentials.new(project)
    return unless creds.github_configured?

    project.ensure_workspace_dir!
    checkout = project.repo_checkout_path

    project.update_columns(repo_checkout_status: "cloning", repo_checkout_error: nil)

    url = GitRunner.github_url(creds.github_repo)

    if Dir.exist?(File.join(checkout, ".git"))
      # This job used to clone with the token in the URL, so older checkouts
      # still hold it in their remote. Rewriting the remote before every pull
      # is what takes it out of them.
      run_git([ "remote", "set-url", "origin", url ], chdir: checkout)
      run_git([ "pull", "--ff-only" ], chdir: checkout, token: creds.github_token)
    else
      FileUtils.mkdir_p(File.dirname(checkout))
      run_git([ "clone", url, checkout ], chdir: File.dirname(checkout), token: creds.github_token)
    end

    project.update_columns(repo_checkout_status: "ready", repo_checkout_error: nil)
  rescue => e
    Rails.logger.error("[ProjectRepoCheckoutJob] #{e.message}")
    project&.update_columns(repo_checkout_status: "error", repo_checkout_error: e.message.to_s.first(500))
  end

  private

  # `token:` only for what talks to GitHub (clone, pull). GitRunner filters the
  # token out of its errors, so the rescue above can log and store them.
  def run_git(args, chdir:, token: nil)
    return self.class.stub_git.call(args, chdir: chdir, token: token) if self.class.stub_git

    GitRunner.run!(*args, chdir: chdir, token: token)
  end
end
