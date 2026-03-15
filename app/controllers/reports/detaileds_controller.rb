module Reports
  class DetailedsController < ApplicationController
    include WorkspaceScoped
    before_action :require_admin!

    def show
      @from = params[:from] ? Date.parse(params[:from]) : Date.current.beginning_of_month
      @to = params[:to] ? Date.parse(params[:to]) : Date.current

      scope = build_scope
      @pagy, @entries = pagy(scope.order(started_at: :desc))

      @total_seconds = scope.sum(:duration_seconds)
      @billable_seconds = scope.sum(:duration_seconds)
      @billable_amount = scope.sum("time_entries.duration_seconds * COALESCE(time_entries.hourly_rate_cents, 0) / 360000.0")

      @projects = current_workspace.projects.active.order(:name)
      @clients = current_workspace.clients.active.order(:name)
      @tags = current_workspace.tags.order(:name)
      @users = current_workspace.users.order(:name)
    end

    def export_csv
      @from = params[:from] ? Date.parse(params[:from]) : Date.current.beginning_of_month
      @to = params[:to] ? Date.parse(params[:to]) : Date.current

      entries = build_scope.order(started_at: :desc)

      csv_data = CSV.generate(headers: true) do |csv|
        csv << [ "Date", "Description", "Project", "Client", "Task", "Tags", "User",
                 "Start", "End", "Duration", "Rate", "Amount" ]

        entries.each do |entry|
          csv << [
            entry.started_at.to_date,
            entry.description,
            entry.project&.name,
            entry.project&.client&.name,
            entry.task&.name,
            entry.tags.map(&:name).join(", "),
            entry.user.name,
            entry.started_at.strftime("%H:%M"),
            entry.stopped_at&.strftime("%H:%M"),
            format_duration_csv(entry.duration_seconds),
            entry.effective_rate_cents / 100.0,
            entry.billable_amount
          ]
        end
      end

      send_data csv_data, filename: "time-report-#{@from}-to-#{@to}.csv", type: "text/csv"
    end

    def export_pdf
      @from = params[:from] ? Date.parse(params[:from]) : Date.current.beginning_of_month
      @to = params[:to] ? Date.parse(params[:to]) : Date.current

      entries = build_scope.order(started_at: :desc)

      pdf = Prawn::Document.new(page_size: "A4", page_layout: :landscape)
      pdf.text "Time Report", size: 20, style: :bold
      pdf.text "#{@from} to #{@to}", size: 12
      pdf.move_down 20

      table_data = [ [ "Date", "Description", "Project", "Duration", "Amount" ] ]
      entries.each do |entry|
        table_data << [
          entry.started_at.to_date.to_s,
          entry.description.to_s.truncate(40),
          entry.project&.name.to_s,
          format_duration_csv(entry.duration_seconds),
          "$#{'%.2f' % entry.billable_amount}"
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
      total_amount = entries.sum(&:billable_amount)

      pdf.move_down 10
      pdf.text "Total: #{format_duration_csv(total_seconds)} | Amount: $#{'%.2f' % total_amount}", style: :bold

      send_data pdf.render, filename: "time-report-#{@from}-to-#{@to}.pdf", type: "application/pdf"
    end

    private

    def build_scope
      scope = current_workspace.time_entries.completed
        .in_range(@from.beginning_of_day, @to.end_of_day)
        .includes(:project, :task, :tags, :user, project: :client)

      scope = scope.where(project_id: params[:project_id]) if params[:project_id].present?
      scope = scope.where(user_id: params[:user_id]) if params[:user_id].present?
      if params[:client_id].present?
        scope = scope.joins(:project).where(projects: { client_id: params[:client_id] })
      end

      if params[:tag_id].present?
        scope = scope.joins(:time_entry_tags).where(time_entry_tags: { tag_id: params[:tag_id] })
      end

      scope
    end

    def format_duration_csv(seconds)
      hours = seconds / 3600
      minutes = (seconds % 3600) / 60
      format("%d:%02d", hours, minutes)
    end
  end
end
