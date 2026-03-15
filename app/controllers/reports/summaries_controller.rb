module Reports
  class SummariesController < ApplicationController
    include WorkspaceScoped

    def show
      @from = params[:from] ? Date.parse(params[:from]) : Date.current.beginning_of_month
      @to = params[:to] ? Date.parse(params[:to]) : Date.current
      @group_by = params[:group_by] || "project"

      scope = build_scope

      @total_seconds = scope.sum(:duration_seconds)
      @billable_seconds = scope.sum(:duration_seconds)
      @billable_amount = scope.sum("time_entries.duration_seconds * COALESCE(time_entries.hourly_rate_cents, 0) / 360000.0")

      @chart_data = build_chart_data(scope)

      # Daily breakdown for bar chart
      @daily_data = scope.group("DATE(started_at)")
        .sum(:duration_seconds)
        .sort_by(&:first)
        .map { |date, seconds| { date: date.to_s, seconds: seconds } }

      @projects = current_workspace.projects.active.order(:name)
      @clients = current_workspace.clients.active.order(:name)
      @tags = current_workspace.tags.order(:name)
    end

    def export_csv
      @from = params[:from] ? Date.parse(params[:from]) : Date.current.beginning_of_month
      @to = params[:to] ? Date.parse(params[:to]) : Date.current
      @group_by = params[:group_by] || "project"

      scope = build_scope
      chart_data = build_chart_data(scope)

      csv_data = CSV.generate(headers: true) do |csv|
        csv << [@group_by.titleize, "Hours", "Percentage"]
        total = scope.sum(:duration_seconds).to_f
        chart_data.each do |data|
          csv << [
            data[:name],
            format("%.2f", data[:seconds] / 3600.0),
            total > 0 ? format("%.1f%%", data[:seconds] / total * 100) : "0%"
          ]
        end
      end

      send_data csv_data, filename: "summary-report-#{@from}-to-#{@to}.csv", type: "text/csv"
    end

    def export_pdf
      @from = params[:from] ? Date.parse(params[:from]) : Date.current.beginning_of_month
      @to = params[:to] ? Date.parse(params[:to]) : Date.current
      @group_by = params[:group_by] || "project"

      scope = build_scope
      chart_data = build_chart_data(scope)
      total_seconds = scope.sum(:duration_seconds)

      pdf = Prawn::Document.new(page_size: "A4")
      pdf.text "Summary Report", size: 20, style: :bold
      pdf.text "#{@from} to #{@to} (by #{@group_by})", size: 12
      pdf.move_down 20

      table_data = [[@group_by.titleize, "Hours", "%"]]
      chart_data.each do |data|
        table_data << [
          data[:name],
          format("%.2f", data[:seconds] / 3600.0),
          total_seconds > 0 ? format("%.1f%%", data[:seconds].to_f / total_seconds * 100) : "0%"
        ]
      end

      if table_data.size > 1
        pdf.table(table_data, header: true, width: pdf.bounds.width) do
          row(0).font_style = :bold
          row(0).background_color = "DDDDDD"
        end
      else
        pdf.text "No data for this period."
      end

      pdf.move_down 10
      pdf.text "Total: #{format('%.2f', total_seconds / 3600.0)} hours", style: :bold

      send_data pdf.render, filename: "summary-report-#{@from}-to-#{@to}.pdf", type: "application/pdf"
    end

    private

    def build_chart_data(scope)
      case @group_by
      when "project"
        scope.joins(:project).group("projects.id", "projects.name", "projects.color")
          .sum(:duration_seconds)
          .map { |(id, name, color), seconds| { id: id, name: name, seconds: seconds, color: color } }
      when "client"
        scope.joins(project: :client).group("clients.id", "clients.name")
          .sum(:duration_seconds)
          .map { |(id, name), seconds| { id: id, name: name || "No Client", seconds: seconds, color: "#6B7280" } }
      when "user"
        scope.joins(:user).group("users.id", "users.name")
          .sum(:duration_seconds)
          .map { |(id, name), seconds| { id: id, name: name, seconds: seconds, color: "#3B82F6" } }
      when "tag"
        scope.joins(:tags).group("tags.id", "tags.name", "tags.color")
          .sum(:duration_seconds)
          .map { |(id, name, color), seconds| { id: id, name: name, seconds: seconds, color: color } }
      else
        []
      end
    end

    def build_scope
      scope = current_workspace.time_entries.completed
        .in_range(@from.beginning_of_day, @to.end_of_day)
        .includes(:project, :task, :tags, :user)

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
  end
end
