module Reports
  class DetailedsController < ApplicationController
    include WorkspaceScoped
    before_action :require_admin!

    def show
      last_month = Date.current.prev_month
      @from = params[:from] ? Date.parse(params[:from]) : last_month.beginning_of_month
      @to = params[:to] ? Date.parse(params[:to]) : last_month.end_of_month

      scope = build_scope
      @entries = scope.order(started_at: :asc)

      @total_seconds = scope.sum(:duration_seconds)

      # Group entries by user
      @entries_by_user = {}
      @entries.each do |entry|
        user = entry.user
        @entries_by_user[user] ||= []
        @entries_by_user[user] << entry
      end
      @entries_by_user = @entries_by_user.sort_by { |user, entries| -entries.sum(&:duration_seconds) }

      # User totals for header stats
      @user_totals = @entries_by_user.map { |user, entries| { user: user, seconds: entries.sum(&:duration_seconds) } }

      @project = current_workspace.projects.find_by(id: params[:project_id])
      @projects = current_workspace.projects.active.order(:name)
      @users = current_workspace.users.order(:name)
    end

    def export_csv
      last_month = Date.current.prev_month
      @from = params[:from] ? Date.parse(params[:from]) : last_month.beginning_of_month
      @to = params[:to] ? Date.parse(params[:to]) : last_month.end_of_month

      entries = build_scope.order(started_at: :asc)

      csv_data = CSV.generate(headers: true) do |csv|
        csv << [ "Date", "User", "Project", "Task", "Description", "Start", "End", "Duration" ]

        entries.each do |entry|
          csv << [
            entry.started_at.to_date,
            entry.user.name,
            entry.project&.name,
            entry.task&.name,
            entry.description,
            entry.started_at.strftime("%H:%M"),
            entry.stopped_at&.strftime("%H:%M"),
            format_duration_csv(entry.duration_seconds)
          ]
        end
      end

      send_data csv_data, filename: "detailed-report-#{@from}-to-#{@to}.csv", type: "text/csv"
    end

    def export_pdf
      last_month = Date.current.prev_month
      @from = params[:from] ? Date.parse(params[:from]) : last_month.beginning_of_month
      @to = params[:to] ? Date.parse(params[:to]) : last_month.end_of_month

      entries = build_scope.order(started_at: :asc)

      pdf = Prawn::Document.new(page_size: "A4", page_layout: :landscape)
      pdf.text "Detailed Report", size: 20, style: :bold
      pdf.text "#{@from} to #{@to}", size: 12
      pdf.move_down 20

      table_data = [[ "Date", "User", "Project", "Task", "Description", "Duration" ]]
      entries.each do |entry|
        table_data << [
          entry.started_at.to_date.to_s,
          entry.user.name,
          entry.project&.name.to_s,
          entry.task&.name.to_s,
          entry.description.to_s.truncate(40),
          format_duration_csv(entry.duration_seconds)
        ]
      end

      if table_data.size > 1
        pdf.table(table_data, header: true, width: pdf.bounds.width) do
          row(0).font_style = :bold
          row(0).background_color = "DDDDDD"
        end
      else
        pdf.text "No time entries found for this period."
      end

      total_seconds = entries.sum(&:duration_seconds)
      pdf.move_down 10
      pdf.text "Total: #{format_duration_csv(total_seconds)}", style: :bold

      send_data pdf.render, filename: "detailed-report-#{@from}-to-#{@to}.pdf", type: "application/pdf"
    end

    private

    def build_scope
      scope = current_workspace.time_entries.completed
        .in_range(@from.beginning_of_day, @to.end_of_day)
        .includes(:project, :task, :user)

      scope = scope.where(project_id: params[:project_id]) if params[:project_id].present?
      scope = scope.where(user_id: params[:user_id]) if params[:user_id].present?

      scope
    end

    def format_duration_csv(seconds)
      hours = seconds / 3600
      minutes = (seconds % 3600) / 60
      format("%d:%02d", hours, minutes)
    end
  end
end
