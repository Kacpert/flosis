require "digest"

# The task's branch in the app's repo (Finish, Kacper, 2026-11-21): one commit
# holding TaskFile's files, made through GitHub's Git Data API with the
# project's app token, from the project's branch or the repo's default one.
# A branch that exists gets a commit on top, only when a file changed, and is
# never forced: a developer may already work on it. Attachments the task no
# longer has leave the folder.
#
# The task remembers the branch, its last commit and when, or why GitHub
# refused it; Ready shows either.
class TaskBranch
  def initialize(task, client: GithubClient.for_project(task.project))
    @task = task
    @client = client
  end

  # { ok:, branch:, sha:, error: }
  def push!
    return failure("This project has no GitHub repository and token (Configuration › GitHub).") unless @client.configured?

    file = TaskFile.new(@task)
    existing = @client.branch_sha(branch)
    parent = existing || base_head
    tree = @client.commit_tree_sha(parent)
    held = existing ? held_files(file) : {}
    entries = file.entries.map { |path, contents| { path: path, mode: "100644", type: "blob", sha: blob(held[path], contents.call) } }
    gone = held.keys.select { |path| path.start_with?("#{file.folder}/attachments/") } - entries.map { |entry| entry[:path] }
    entries += gone.map { |path| { path: path, mode: "100644", type: "blob", sha: nil } }
    new_tree = @client.create_tree(base_tree: tree, entries: entries)
    return success(parent, create: !existing) if new_tree == tree

    sha = @client.create_commit(message: "#{file.key}: task description #{file.version || 'v1'}", tree: new_tree, parents: [ parent ])
    existing ? @client.update_ref(branch, sha) : @client.create_ref(branch, sha)
    success(sha)
  rescue GithubClient::Error => e
    failure(explain(e))
  rescue StandardError => e
    # Whatever else breaks on the way (a dropped connection, an attachment
    # gone from storage) is recorded, never raised: Finish has written Jira by
    # now (review I4).
    Rails.logger.error("[TaskBranch] task #{@task.id}: #{e.class}: #{e.message}")
    failure("The branch could not be written: #{e.message.truncate(300)}")
  end

  private

  def branch
    @branch ||= @task.code_branch.presence || @task.suggested_branch
  end

  def base_head
    base = @task.project.github_branch.presence || @client.default_branch
    @client.branch_sha(base) or raise GithubClient::Error, "The branch #{base} is not on GitHub, so there is nothing to start from."
  end

  # What the branch already holds in the task's folder, by path: its git blob
  # shas, so an unchanged file is not sent again.
  def held_files(file)
    @client.folder_files(file.folder, ref: branch).merge(@client.folder_files("#{file.folder}/attachments", ref: branch))
  end

  # The blob for a file's contents: the one the branch holds when it is the
  # same (git's own sha of it), else a new one.
  def blob(held, contents)
    bytes = contents.to_s.b
    return held if held && held == Digest::SHA1.hexdigest("blob #{bytes.bytesize}\0".b + bytes)

    @client.create_blob(bytes)
  end

  def explain(error)
    if [ 401, 403, 404 ].include?(error.status)
      "The project's GitHub token can't write to #{ProjectCredentials.new(@task.project).github_repo} (#{error.status}). " \
        "It needs Contents: write — Configuration › GitHub."
    else
      "GitHub refused the branch: #{error.message.truncate(300)}"
    end
  end

  # A new branch whose files the base already holds is still created, at the
  # base's head.
  def success(sha, create: false)
    @client.create_ref(branch, sha) if create
    @task.update!(code_branch: branch, code_branch_sha: sha, code_branch_pushed_at: Time.current, code_branch_error: nil)
    { ok: true, branch: branch, sha: sha, error: nil }
  end

  def failure(error)
    @task.update!(code_branch_error: error)
    { ok: false, branch: branch, sha: nil, error: error }
  end
end
