module Reports
  class WeekliesController < ApplicationController
    include WorkspaceScoped

    def show
      @week_start = if params[:week_of]
        Date.parse(params[:week_of]).beginning_of_week(:monday)
      else
        Date.current.beginning_of_week(:monday)
      end

      @week_days = (0..6).map { |i| @week_start + i.days }
      @group_by = params[:group_by] || "user"

      entries = build_entries

      # Build grid: { group_name => { date => seconds } }
      @grid = {}
      entries.each do |entry|
        group_name = case @group_by
        when "user" then entry.user.name
        when "project" then entry.project&.name || "No Project"
        else entry.user.name
        end

        @grid[group_name] ||= {}
        date = entry.started_at.to_date
        @grid[group_name][date] = (@grid[group_name][date] || 0) + entry.duration_seconds
      end

      @day_totals = {}
      @week_days.each do |day|
        @day_totals[day] = entries.select { |e| e.started_at.to_date == day }.sum(&:duration_seconds)
      end

      @projects = current_workspace.projects.active.order(:name)
    end

    def export_csv
      @week_start = if params[:week_of]
        Date.parse(params[:week_of]).beginning_of_week(:monday)
      else
        Date.current.beginning_of_week(:monday)
      end

      @week_days = (0..6).map { |i| @week_start + i.days }
      @group_by = params[:group_by] || "user"

      entries = build_entries

      grid = {}
      entries.each do |entry|
        group_name = case @group_by
        when "user" then entry.user.name
        when "project" then entry.project&.name || "No Project"
        else entry.user.name
        end

        grid[group_name] ||= {}
        date = entry.started_at.to_date
        grid[group_name][date] = (grid[group_name][date] || 0) + entry.duration_seconds
      end

      csv_data = CSV.generate(headers: true) do |csv|
        csv << [@group_by.titleize] + @week_days.map { |d| d.strftime("%a %b %d") } + ["Total"]
        grid.each do |name, days|
          total = days.values.sum
          csv << [name] + @week_days.map { |d|
            seconds = days[d] || 0
            seconds > 0 ? format("%.2f", seconds / 3600.0) : ""
          } + [format("%.2f", total / 3600.0)]
        end
      end

      send_data csv_data, filename: "weekly-report-#{@week_start}.csv", type: "text/csv"
    end

    def export_pdf
      @week_start = if params[:week_of]
        Date.parse(params[:week_of]).beginning_of_week(:monday)
      else
        Date.current.beginning_of_week(:monday)
      end

      @week_days = (0..6).map { |i| @week_start + i.days }
      @group_by = params[:group_by] || "user"

      entries = build_entries

      grid = {}
      entries.each do |entry|
        group_name = case @group_by
        when "user" then entry.user.name
        when "project" then entry.project&.name || "No Project"
        else entry.user.name
        end

        grid[group_name] ||= {}
        date = entry.started_at.to_date
        grid[group_name][date] = (grid[group_name][date] || 0) + entry.duration_seconds
      end

      pdf = Prawn::Document.new(page_size: "A4", page_layout: :landscape)
      pdf.text "Weekly Report", size: 20, style: :bold
      pdf.text "#{@week_start.strftime('%b %d')} - #{(@week_start + 6.days).strftime('%b %d, %Y')} (by #{@group_by})", size: 12
      pdf.move_down 20

      table_data = [[@group_by.titleize] + @week_days.map { |d| d.strftime("%a %d") } + ["Total"]]
      grid.each do |name, days|
        total = days.values.sum
        table_data << [name] + @week_days.map { |d|
          seconds = days[d] || 0
          seconds > 0 ? format("%d:%02d", seconds / 3600, (seconds % 3600) / 60) : ""
        } + [format("%d:%02d", total / 3600, (total % 3600) / 60)]
      end

      if table_data.size > 1
        pdf.table(table_data, header: true, width: pdf.bounds.width) do
          row(0).font_style = :bold
          row(0).background_color = "DDDDDD"
        end
      else
        pdf.text "No data for this week."
      end

      grand_total = grid.values.flat_map(&:values).sum
      pdf.move_down 10
      pdf.text "Total: #{format('%d:%02d', grand_total / 3600, (grand_total % 3600) / 60)}", style: :bold

      send_data pdf.render, filename: "weekly-report-#{@week_start}.pdf", type: "application/pdf"
    end

    private

    def build_entries
      entries = current_workspace.time_entries.completed
        .in_range(@week_start.beginning_of_day, (@week_start + 6.days).end_of_day)
        .includes(:project, :user)

      if params[:project_id].present?
        entries = entries.where(project_id: params[:project_id])
      end

      entries
    end
  end
end
