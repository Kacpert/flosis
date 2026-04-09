module Reports
  class SummariesController < ApplicationController
    include WorkspaceScoped
    before_action :require_admin!

    def show
      last_month = Date.current.prev_month
      @from = params[:from] ? Date.parse(params[:from]) : last_month.beginning_of_month
      @to = params[:to] ? Date.parse(params[:to]) : last_month.end_of_month

      scope = build_scope

      @total_seconds = scope.sum(:duration_seconds)

      # User breakdown with percentages
      @user_data = scope.joins(:user).group("users.id", "users.name")
        .sum(:duration_seconds)
        .map { |(id, name), seconds| { id: id, name: name, seconds: seconds } }
        .sort_by { |d| -d[:seconds] }

      # Per-project breakdown with user hours
      @project_data = scope.joins(:project, :user)
        .group("projects.id", "projects.name", "projects.color", "users.id", "users.name")
        .sum(:duration_seconds)

      @projects_summary = {}
      @project_data.each do |(proj_id, proj_name, proj_color, user_id, user_name), seconds|
        @projects_summary[proj_id] ||= { name: proj_name, color: proj_color, total: 0, users: {} }
        @projects_summary[proj_id][:total] += seconds
        @projects_summary[proj_id][:users][user_id] ||= { name: user_name, seconds: 0 }
        @projects_summary[proj_id][:users][user_id][:seconds] += seconds
      end
      @projects_summary = @projects_summary.sort_by { |_, v| -v[:total] }.to_h

      @projects = current_workspace.projects.active.order(:name)
    end

    def export_csv
      last_month = Date.current.prev_month
      @from = params[:from] ? Date.parse(params[:from]) : last_month.beginning_of_month
      @to = params[:to] ? Date.parse(params[:to]) : last_month.end_of_month

      scope = build_scope

      user_data = scope.joins(:user).group("users.id", "users.name")
        .sum(:duration_seconds)
        .map { |(id, name), seconds| { name: name, seconds: seconds } }
        .sort_by { |d| -d[:seconds] }

      total = scope.sum(:duration_seconds).to_f

      csv_data = CSV.generate(headers: true) do |csv|
        csv << [ "User", "Hours", "Percentage" ]
        user_data.each do |data|
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
      last_month = Date.current.prev_month
      @from = params[:from] ? Date.parse(params[:from]) : last_month.beginning_of_month
      @to = params[:to] ? Date.parse(params[:to]) : last_month.end_of_month

      scope = build_scope
      total_seconds = scope.sum(:duration_seconds)

      user_data = scope.joins(:user).group("users.id", "users.name")
        .sum(:duration_seconds)
        .map { |(id, name), seconds| { name: name, seconds: seconds } }
        .sort_by { |d| -d[:seconds] }

      pdf = Prawn::Document.new(page_size: "A4")
      pdf.text "Summary Report", size: 20, style: :bold
      pdf.text "#{@from} to #{@to}", size: 12
      pdf.move_down 20

      table_data = [[ "User", "Hours", "%" ]]
      user_data.each do |data|
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

    def build_scope
      scope = current_workspace.time_entries.completed
        .in_range(@from.beginning_of_day, @to.end_of_day)
        .includes(:project, :task, :user)

      scope = scope.where(project_id: params[:project_id]) if params[:project_id].present?
      scope = scope.where(user_id: params[:user_id]) if params[:user_id].present?

      scope
    end
  end
end
