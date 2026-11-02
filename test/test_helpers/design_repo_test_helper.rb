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

  # master as Flosis starts it: the files the test needs, beside the runtime
  # that marks a master as Flosis's (ensure_clone! refuses any other).
  def seed_master(repo, files = { "README.md" => "hi\n" })
    repo.ensure_clone!
    commit_files(repo, repo.root, { Designs::Repo::RUNTIME => "// the runtime\n" }.merge(files))
    repo.push!("master")
    repo.ensure_clone!
    repo.head("master")
  end

  def remote_branch_sha(remote, branch)
    out, status = Open3.capture2("git", "-C", remote, "rev-parse", "--verify", "--quiet", "refs/heads/#{branch}")
    status.success? ? out.strip : nil
  end

  # Commits files onto a branch of the remote from a clone of its own, as
  # GitHub or a developer would.
  def push_from_elsewhere(remote, branch, files)
    Dir.mktmpdir("elsewhere") do |dir|
      system("git", "clone", "--quiet", remote, dir, exception: true, err: File::NULL)
      files.each do |path, body|
        FileUtils.mkdir_p(File.dirname(File.join(dir, path)))
        File.write(File.join(dir, path), body)
      end
      system("git", "-C", dir, "add", "-A", exception: true)
      system("git", "-C", dir, "-c", "user.name=Someone", "-c", "user.email=someone@example.com",
             "commit", "--quiet", "-m", "Initial commit", exception: true)
      system("git", "-C", dir, "push", "--quiet", "origin", "HEAD:refs/heads/#{branch}", exception: true, err: File::NULL)
    end
  end
end
