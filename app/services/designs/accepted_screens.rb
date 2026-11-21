# A task's accepted designs (2026-11-21): the task's merges that kept an
# accepted copy, and, from the newest one on disk, the screens it changed, as
# that copy recorded them (__flosis/changes.json, __flosis/screens.json). The
# merges keep their task when a thread is deleted or unlinked, so the task's
# lasting link, its Designs section, its file and Jira's links outlive the
# thread.
class Designs::AcceptedScreens
  def initialize(task)
    @task = task
    @publisher = Designs::Publisher.new(task.project, nil)
  end

  # The task's merges with an accepted copy, oldest first.
  def merges
    @merges ||= @task.design_merges.where.not(slot: nil).order(:merged_at, :id).to_a
  end

  def slot = newest&.slot
  def any? = !newest.nil?

  # [{ context:, context_name:, screen:, name:, kind: }], as the copy lists them.
  def own
    return [] unless any?

    contexts = Array(screens["contexts"]).to_h { |context| [ context["id"], context["name"] ] }
    names = Array(screens["screens"]).to_h { |screen| [ [ screen["context"], screen["id"] ], screen["name"] ] }
    Array(changes["own"]).map do |context, screen, kind|
      { context: context, context_name: contexts[context] || context.to_s.humanize, screen: screen,
        name: names[[ context, screen ]] || screen.to_s.humanize, kind: kind }
    end
  end

  # The shared components whose change reached other screens, by name.
  def through_names
    any? && changes["through"].is_a?(Hash) ? changes["through"].keys : []
  end

  private

  def newest
    return @newest if defined?(@newest)

    @newest = merges.reverse.find { |merge| published?(merge.slot) }
  end

  def published?(slot)
    @publisher.published?(slot)
  rescue ArgumentError
    false
  end

  def changes = @changes ||= read("changes.json")
  def screens = @screens ||= read("screens.json")

  def read(name)
    file = @publisher.slot_folder(slot)&.join("__flosis", name)
    file&.file? ? JSON.parse(file.read) : {}
  rescue JSON::ParserError
    {}
  end
end
