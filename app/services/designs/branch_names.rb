# Names for a task's design-repo branches and approval tags. The slug is the
# Jira key when the task has one, else "task-<id>": nothing else from a task
# ever becomes part of a git ref. A task with neither is refused.
module Designs::BranchNames
  MASTER = "master".freeze
  SETUP = "wip/setup".freeze
  JIRA_KEY = /\A[A-Z][A-Z0-9_]+-\d+\z/

  module_function

  def slug(task)
    key = task.external_reference
    return key if JIRA_KEY.match?(key)
    # An unsaved task would be "task-", and so would every other one.
    raise ArgumentError, "a task with no Jira key is named after its id, and this one is not saved yet" if task.id.nil?

    "task-#{task.id}"
  end

  def wip(task)
    "wip/#{slug(task)}"
  end

  def design(task)
    "design/#{slug(task)}"
  end

  def approval_tag(slug, n)
    "approved/#{slug}/#{n}"
  end
end
