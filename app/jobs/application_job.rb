class ApplicationJob < ActiveJob::Base
  # Automatically retry jobs that encountered a deadlock
  # retry_on ActiveRecord::Deadlocked

  # Most jobs are safe to ignore if the underlying records are no longer available
  # discard_on ActiveJob::DeserializationError

  private

  # The directory a job may run Claude in for this project, or nil with a line
  # saying why. Shared because five jobs ask it and all five must answer the
  # same way: a project with no checkout of its own gets no AI answer at all,
  # rather than a confident one about the codebase next door.
  def ai_codebase_path(project)
    project.ai_codebase_path.tap do |path|
      next if path

      Rails.logger.warn("[#{self.class.name}] project #{project.id} (#{project.name}) " \
                        "has no codebase checkout of its own — skipping")
    end
  end
end
