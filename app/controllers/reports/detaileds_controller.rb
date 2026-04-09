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

      entries = build_scope.order(started_at: :asc).to_a
      project = current_workspace.projects.find_by(id: params[:project_id])
      total_seconds = entries.sum(&:duration_seconds)

      # Group by user, sorted by most hours
      entries_by_user = {}
      entries.each do |entry|
        entries_by_user[entry.user] ||= []
        entries_by_user[entry.user] << entry
      end
      entries_by_user = entries_by_user.sort_by { |_, ents| -ents.sum(&:duration_seconds) }

      pdf = Prawn::Document.new(page_size: "A4")
      font_dir = Rails.root.join("app/assets/fonts")
      pdf.font_families.update("Inter" => {
        normal: font_dir.join("Inter-Regular.ttf").to_s,
        bold: font_dir.join("Inter-Bold.ttf").to_s
      })
      pdf.font "Inter"

      # --- Title ---
      title = project ? "#{project.name} — Detailed Report" : "Detailed Report"
      pdf.text title, size: 18, style: :bold
      pdf.text "#{@from.strftime('%B %d, %Y')} to #{@to.strftime('%B %d, %Y')}", size: 10, color: "666666"
      pdf.move_down 5
      pdf.text "Total: #{format_duration_csv(total_seconds)}", size: 12, style: :bold
      pdf.move_down 15

      # --- Team Recap Table ---
      if entries_by_user.size > 1
        pdf.text "Team Overview", size: 13, style: :bold
        pdf.move_down 8

        recap_data = [[ "Team Member", "Hours", "%" ]]
        entries_by_user.each do |user, ents|
          user_seconds = ents.sum(&:duration_seconds)
          pct = total_seconds > 0 ? (user_seconds.to_f / total_seconds * 100).round(1) : 0
          recap_data << [ user.name, format_duration_csv(user_seconds), "#{pct}%" ]
        end

        pdf.table(recap_data, header: true, width: pdf.bounds.width, cell_style: { size: 9, padding: [6, 8] }) do
          row(0).font_style = :bold
          row(0).background_color = "F0F0F0"
          column(1).align = :right
          column(2).align = :right
        end
        pdf.move_down 20
      end

      # --- Per-User Sections ---
      entries_by_user.each_with_index do |(user, user_entries), idx|
        user_seconds = user_entries.sum(&:duration_seconds)
        user_pct = total_seconds > 0 ? (user_seconds.to_f / total_seconds * 100).round(1) : 0

        # Start new page for each user after the first if needed
        pdf.start_new_page if idx > 0

        # User header
        pdf.text user.name, size: 14, style: :bold
        pdf.text "#{format_duration_csv(user_seconds)} (#{user_pct}%)", size: 10, color: "666666"
        pdf.move_down 10

        # Group entries by date
        by_date = user_entries.group_by { |e| e.started_at.to_date }.sort_by(&:first)

        by_date.each do |date, day_entries|
          day_total = day_entries.sum(&:duration_seconds)

          # Date header row
          pdf.text "#{date.strftime('%a, %b %-d')}", size: 9, style: :bold, color: "444444"
          pdf.move_down 4

          # Entries table for this date
          show_project = project.nil?
          headers = show_project ? [ "Project", "Task", "Notes", "Time", "Duration" ] : [ "Task", "Notes", "Time", "Duration" ]

          table_data = [ headers ]
          day_entries.sort_by(&:started_at).each do |entry|
            time_str = "#{entry.started_at.strftime('%H:%M')}-#{entry.stopped_at&.strftime('%H:%M')}"
            row = []
            row << entry.project&.name.to_s if show_project
            row << entry.task&.name.to_s
            row << entry.description.to_s.truncate(50)
            row << time_str
            row << format_duration_csv(entry.duration_seconds)
            table_data << row
          end

          # Day total row
          if day_entries.size > 1
            total_row = Array.new(headers.size - 1, "")
            total_row[0] = { content: "Day total", font_style: :bold }
            total_row << { content: format_duration_csv(day_total), font_style: :bold }
            table_data << total_row
          end

          pdf.table(table_data, header: true, width: pdf.bounds.width, cell_style: { size: 8, padding: [4, 5] }) do
            row(0).font_style = :bold
            row(0).background_color = "F5F5F5"
            row(0).size = 7
            column(-1).align = :right
            column(-2).align = :center
          end
          pdf.move_down 8
        end
      end

      if entries.empty?
        pdf.text "No time entries found for this period.", size: 11, color: "999999"
      end

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
