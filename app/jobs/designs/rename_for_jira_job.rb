# Moves a task's designs from task-<id> to its Jira key once the issue
# exists: the working and design branches (worktree folder included, and on
# GitHub), every approval tag and its record (Ruling P4-R2), the task's
# manifest file, and the previews. Then the Designs chat points at the
# renamed worktree, and the latest approval's Jira links go out, now that
# there is an issue to put them on.
#
# It runs under the same per-task lock as the task's turns, so nothing works
# in the worktree meanwhile. Each step skips what is already done, so a run
# that was cut off can be run again.
class Designs::RenameForJiraJob < ApplicationJob
  queue_as :designs

  limits_concurrency to: 1, group: Designs::TurnJob::CONCURRENCY_GROUP, duration: 2.hours,
                     key: ->(task_id) { self.class.concurrency_key_for(task_id) }

  KINDS = %w[wip design].freeze

  def self.concurrency_key_for(task_id)
    Designs::TurnJob.concurrency_key_for(task_id)
  end

  def perform(task_id)
    task = Task.find_by(id: task_id)
    return unless task && Designs::BranchNames::JIRA_KEY.match?(task.external_reference.to_s)

    old = "task-#{task.id}"
    key = task.external_reference
    repo = Designs::Repo.new(task.project)
    return unless rename(repo, task, old, key)

    ChatSession.where(task: task, purpose: "designs").update_all(codebase_path: repo.worktree_path("wip/#{key}").to_s)
    latest = task.design_approvals.order(:number).last
    Designs::SyncJiraLinksJob.perform_later(latest.id) if latest
  end

  private

  # False when the task has nothing under its old name.
  def rename(repo, task, old, key)
    repo.synchronize do
      repo.ensure_clone!
      branches = KINDS.select { |kind| repo.head("#{kind}/#{old}") || repo.remote_head("#{kind}/#{old}") }
      tags = repo.tags(Designs::BranchNames.approval_tag(old, "*"))
      next false if branches.empty? && tags.empty?

      branches.each { |kind| rename_branch(repo, "#{kind}/#{old}", "#{kind}/#{key}") }
      tags.each { |tag| move_tag(repo, task, tag, key) }
      move_manifest(repo, task, old, key)
      publish(repo, task, old, key)
      true
    end
  end

  # A branch only origin has (a clone made afresh) is made local first.
  def rename_branch(repo, from, to)
    repo.point!(from, to: repo.remote_head(from)) unless repo.head(from)
    repo.rename!(from, to)
  end

  def move_tag(repo, task, tag, key)
    renamed = Designs::BranchNames.approval_tag(key, tag.split("/").last)
    repo.tag!(renamed, at: tag)
    repo.push!(renamed)
    repo.delete_tag!(tag, remote: true)
    task.design_approvals.where(tag: tag).update_all(tag: renamed)
  end

  # The manifest is named after the task, and the screen reads it by name.
  # The move is committed as a turn's work is, through the guard.
  def move_manifest(repo, task, old, key)
    wip = "wip/#{key}"
    return unless repo.head(wip)

    dir = repo.worktree!(wip)
    repo.discard!(dir)
    from = dir.join("designs/tasks/#{old}.json")
    to = dir.join("designs/tasks/#{key}.json")
    return unless from.file? && !to.exist?

    FileUtils.mv(from, to)
    guard = Designs::LeakGuard.new(forbidden_texts: Designs::Library.compose(task.project).texts,
                                   secrets: ProjectCredentials.new(task.project).all_secrets)
    result = Designs::Committer.new(repo, guard).commit!(dir, message: "#{key}: the manifest takes the Jira key")
    raise "Refused: #{result.refusal}" unless result.ok?

    repo.push!(wip)
  end

  # The previews move too. A failure here is logged and nothing more: the
  # next turn publishes the working branch and the next approval the design.
  def publish(repo, task, old, key)
    publisher = Designs::Publisher.new(task.project, repo)
    publisher.publish!("design/#{key}", key) if repo.head("design/#{key}")
    publisher.publish!("wip/#{key}", "wip/#{key}") if repo.head("wip/#{key}") && repo.commits_ahead("wip/#{key}").positive?
    publisher.unpublish!(old)
    publisher.unpublish!("wip/#{old}")
  rescue StandardError => e
    Rails.logger.error("[#{self.class.name}] task #{task.id}: previews not moved: #{e.class}: #{e.message}")
  end
end
