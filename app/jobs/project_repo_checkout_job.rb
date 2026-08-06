require "fileutils"

# Clones (or fast-forward pulls) a project's repo into its isolated folder,
# using the resolved GitHub token. Enqueued when the GitHub integration is
# saved. Legacy elvium is skipped (it uses the shared ~/work/elvium checkout).
class ProjectRepoCheckoutJob < ApplicationJob
  queue_as :default

  # Test seam: a lambda ->(cmd, chdir:) that runs a git command. Nil in prod.
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

    if Dir.exist?(File.join(checkout, ".git"))
      run_git(["git", "pull", "--ff-only"], chdir: checkout)
    else
      url = "https://#{creds.github_token}@github.com/#{creds.github_repo}.git"
      FileUtils.mkdir_p(File.dirname(checkout))
      run_git(["git", "clone", url, checkout], chdir: File.dirname(checkout))
    end

    project.update_columns(repo_checkout_status: "ready", repo_checkout_error: nil)
  rescue => e
    Rails.logger.error("[ProjectRepoCheckoutJob] #{e.message}")
    project&.update_columns(repo_checkout_status: "error", repo_checkout_error: e.message.to_s.first(500))
  end

  private

  def run_git(cmd, chdir:)
    return self.class.stub_git.call(cmd, chdir: chdir) if self.class.stub_git

    ok = system(*cmd, chdir: chdir, out: File::NULL, err: File::NULL)
    raise "git failed: #{cmd.reject { |a| a.include?('@github.com') }.join(' ')}" unless ok
    true
  end
end
