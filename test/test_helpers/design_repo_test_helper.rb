require "open3"

# A bare repository on disk stands in for GitHub, so the git plumbing is tested
# for real without the network.
module DesignRepoTestHelper
  def with_design_remote(project = projects(:jira_project))
    dir = Dir.mktmpdir("design-remote")
    remote = File.join(dir, "remote.git")
    system("git", "init", "--bare", "--quiet", remote, exception: true)
    system("git", "-C", remote, "symbolic-ref", "HEAD", "refs/heads/master", exception: true)
    project.update!(workspace_dir: File.join(dir, "workspace"), design_repo: "acme/designs",
                    design_repo_token: "design-token", designs_enabled: true)
    yield Designs::Repo.new(project, remote_url: remote), remote
  ensure
    FileUtils.remove_entry(dir) if dir && File.exist?(dir)
  end

  def with_remote_url(url)
    Designs::Repo.remote_url_override = url
    yield
  ensure
    Designs::Repo.remote_url_override = nil
  end

  def commit_files(repo, dir, files, message: "test")
    files.each do |path, body|
      FileUtils.mkdir_p(File.dirname(File.join(dir, path)))
      File.write(File.join(dir, path), body)
    end
    repo.stage_all!(dir)
    repo.commit!(dir, message: message)
  end

  def seed_master(repo, files = { "README.md" => "hi\n" })
    repo.ensure_clone!
    commit_files(repo, repo.root, files)
    repo.push!("master")
    repo.ensure_clone!
    repo.head("master")
  end

  def remote_branch_sha(remote, branch)
    out, status = Open3.capture2("git", "-C", remote, "rev-parse", "--verify", "--quiet", "refs/heads/#{branch}")
    status.success? ? out.strip : nil
  end
end
