module Api
  module V1
    # Books COMPLETED work only: an entry always has an end, given either as
    # stopped_at or as duration_minutes. The API never starts a running timer,
    # and it cannot read, change or delete entries — the token is for adding
    # hours, nothing more.
    class TimeEntriesController < BaseController
      MAX_DURATION = 24.hours
      TIME_FORMAT = /\A\d{4}-\d{2}-\d{2}[T ]\d{1,2}:\d{2}/

      before_action { require_scope!("time_entries:create") }

      def create
        attrs = params.permit(:project_id, :description, :started_at, :stopped_at, :duration_minutes, :task_key)

        project = bookable_projects.find_by(id: attrs[:project_id])
        return unprocessable("project_id is missing or not one of your projects. GET /api/v1/projects lists them.") unless project

        started_at = parse_time(attrs[:started_at])
        return unprocessable("started_at is required, ISO 8601, e.g. 2026-11-04T09:00:00+01:00 (no offset = Europe/Warsaw).") unless started_at

        stopped_at, problem = resolve_end(started_at, attrs)
        return unprocessable(problem) if problem

        task = nil
        if attrs[:task_key].present?
          task = project.tasks.find_by(external_reference: attrs[:task_key].to_s.strip.upcase)
          return unprocessable("task_key #{attrs[:task_key]} is not a task of project #{project.name}. Leave task_key out and mention it in the description instead.") unless task
        end

        entry = api_workspace.time_entries.build(user: api_user, project: project, task: task,
                                                 description: attrs[:description].to_s.strip.presence,
                                                 started_at: started_at, stopped_at: stopped_at)
        if entry.save
          render json: { time_entry: serialize(entry) }, status: :created
        else
          unprocessable("The time entry was not saved.", details: entry.errors.full_messages)
        end
      end

      private

      def resolve_end(started_at, attrs)
        if attrs[:stopped_at].present?
          stopped_at = parse_time(attrs[:stopped_at])
          return [ nil, "stopped_at is not an ISO 8601 date and time." ] unless stopped_at
        elsif attrs[:duration_minutes].present?
          minutes = Integer(attrs[:duration_minutes].to_s, exception: false)
          return [ nil, "duration_minutes must be a whole number of minutes." ] unless minutes
          stopped_at = started_at + minutes.minutes
        else
          return [ nil, "Give either stopped_at or duration_minutes." ]
        end

        return [ nil, "The entry must end after it starts." ] unless stopped_at > started_at
        return [ nil, "One entry can be at most 24 hours long." ] if stopped_at - started_at > MAX_DURATION

        [ stopped_at, nil ]
      end

      def parse_time(value)
        value = value.to_s.strip
        return unless value.match?(TIME_FORMAT)

        Time.zone.parse(value)
      rescue ArgumentError
        nil
      end

      def unprocessable(message, details: nil)
        render_error(:unprocessable_entity, message, details: details)
      end

      def serialize(entry)
        {
          id: entry.id,
          project_id: entry.project_id,
          project: entry.project.name,
          task_key: entry.task&.external_reference,
          description: entry.description,
          started_at: entry.started_at.iso8601,
          stopped_at: entry.stopped_at.iso8601,
          duration_minutes: entry.duration_seconds / 60
        }
      end
    end
  end
end
