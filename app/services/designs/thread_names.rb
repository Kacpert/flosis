# The branch a design thread works on (Workshop Designs v2): design/<KEY>-<slug>
# for a thread started from a task, design/<slug> otherwise. The slug is the
# first four words of the change; a task without a Jira issue is task-<id>
# (Designs::BranchNames.slug). A name the project already has gets -2, -3, ….
# Names never change after that, so a task that gets its Jira key later keeps
# the branch it started on.
module Designs::ThreadNames
  PREFIX = "design/".freeze
  WORDS = 4

  module_function

  def key(task) = Designs::BranchNames.slug(task)

  def branch_for(project:, text:, task: nil)
    words = text.to_s.parameterize.split("-").first(WORDS).join("-").presence || "change"
    name = PREFIX + [ task && key(task), words ].compact.join("-")
    taken = project.design_threads.where("branch = ? OR branch LIKE ?", name, "#{name}-%").pluck(:branch).to_set
    return name unless taken.include?(name)

    (2..).each do |n|
      candidate = "#{name}-#{n}"
      return candidate unless taken.include?(candidate)
    end
  end
end
