module Api
  module V1
    # The person's own entries in the token's workspace, never anyone else's.
    # Booking takes COMPLETED work only: an entry always has an end, given
    # either as stopped_at or as duration_minutes, so the API never starts a
    # running timer. Entries cannot be changed, only deleted and booked again,
    # and only from the last DELETABLE_FOR days, counted from when the work
    # started: older hours have been reported and invoiced on.
    class TimeEntriesController < BaseController
      MAX_DURATION = 24.hours
      DELETABLE_FOR = 36.days
      MAX_RANGE = 366.days
      MAX_LISTED = 1000
      TIME_FORMAT = /\A\d{4}-\d{2}-\d{2}[T ]\d{1,2}:\d{2}/

      before_action(only: :index) { require_scope!("time_entries:read") }
      before_action(only: :create) { require_scope!("time_entries:create") }
      before_action(only: :destroy) { require_scope!("time_entries:delete") }

      # from/to are dates (YYYY-MM-DD, Warsaw days, both inclusive); by default
      # the last 36 days, the window entries can still be deleted in.
      def index
        from = params[:from].present? ? parse_date(params[:from]) : DELETABLE_FOR.ago.to_date
        to = params[:to].present? ? parse_date(params[:to]) : Date.current
        return unprocessable("from and to must be dates, YYYY-MM-DD.") unless from && to
        return unprocessable("from must not be after to.") if from > to
        return unprocessable("At most 366 days at a time.") if to - from > MAX_RANGE.in_days

        scope = api_workspace.time_entries.where(user: api_user)
          .in_range(from.beginning_of_day, to.end_of_day)
          .includes(:project, :task)
          .order(started_at: :desc)
        scope = scope.where(project_id: params[:project_id]) if params[:project_id].present?

        entries = scope.limit(MAX_LISTED + 1).to_a
        truncated = entries.size > MAX_LISTED
        entries = entries.first(MAX_LISTED)

        render json: {
          from: from.iso8601, to: to.iso8601, count: entries.size, truncated: truncated,
          total_minutes: entries.sum { |entry| entry.calculated_duration } / 60,
          time_entries: entries.map { |entry| serialize(entry) }
        }
      end

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

      def destroy
        entry = api_workspace.time_entries.where(user: api_user).find_by(id: params[:id])
        return render_error(:not_found, "No time entry #{params[:id]} of yours in this workspace.") unless entry

        unless deletable?(entry)
          return unprocessable("Time entry #{entry.id} started on #{entry.started_at.to_date}, more than 36 days ago; only entries from the last 36 days can be deleted.")
        end

        entry.destroy!
        render json: { deleted: serialize(entry) }
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

      def deletable?(entry)
        entry.started_at >= DELETABLE_FOR.ago
      end

      def parse_date(value)
        value = value.to_s.strip
        return unless value.match?(/\A\d{4}-\d{2}-\d{2}\z/)

        Date.iso8601(value)
      rescue Date::Error
        nil
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
          stopped_at: entry.stopped_at&.iso8601,
          running: entry.running?,
          duration_minutes: entry.calculated_duration / 60,
          deletable: deletable?(entry)
        }
      end
    end
  end
end
