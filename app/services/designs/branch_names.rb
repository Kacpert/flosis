# Names for a task's design-repo branches and approval tags. The slug is the
# Jira key when the task has one, else "task-<id>": nothing else from a task
# ever becomes part of a git ref.
module Designs::BranchNames
  MASTER = "master".freeze
  SETUP = "wip/setup".freeze
  JIRA_KEY = /\A[A-Z][A-Z0-9_]+-\d+\z/

  module_function

  def slug(task)
    key = task.external_reference
    JIRA_KEY.match?(key) ? key : "task-#{task.id}"
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
