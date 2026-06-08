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

      # Cost uses each member's CURRENT project rate (not the entry's frozen
      # snapshot), so setting/updating a rate is reflected for past entries too.
      # `@cost_for` is a callable the view also uses for per-user sums.
      @rate_lookup = current_rate_lookup(@entries)
      @cost_for = ->(entry) {
        rate = @rate_lookup[[entry.project_id, entry.user_id]] || 0
        (entry.duration_seconds / 3600.0 * rate).round
      }
      @total_cents = @entries.sum { |e| @cost_for.call(e) }

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

      entries_by_user = {}
      entries.each do |entry|
        entries_by_user[entry.user] ||= []
        entries_by_user[entry.user] << entry
      end
      entries_by_user = entries_by_user.sort_by { |_, ents| -ents.sum(&:duration_seconds) }

      pdf_bytes = build_detailed_pdf(
        from: @from,
        to: @to,
        project: project,
        entries: entries,
        entries_by_user: entries_by_user,
        total_seconds: total_seconds
      )

      send_data pdf_bytes, filename: "detailed-report-#{@from}-to-#{@to}.pdf", type: "application/pdf"
    end

    private

    # Map of [project_id, user_id] => current hourly_rate_cents, loaded in one
    # query for just the (project, user) pairs present in the entries.
    def current_rate_lookup(entries)
      pairs = entries.map { |e| [ e.project_id, e.user_id ] }.uniq
      return {} if pairs.empty?

      project_ids = pairs.map(&:first).uniq
      user_ids = pairs.map(&:last).uniq

      ProjectMembership
        .where(project_id: project_ids, user_id: user_ids)
        .pluck(:project_id, :user_id, :hourly_rate_cents)
        .each_with_object({}) { |(pid, uid, cents), h| h[[pid, uid]] = cents }
    end

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

    PDF_INK       = "1F1F1F"
    PDF_MUTED     = "6B6B6B"
    PDF_FAINT     = "9A9A9A"
    PDF_RULE      = "E2E2E2"
    PDF_STRIPE    = "FAFAF7"
    PDF_HEADER_BG = "EFEDE5"
    PDF_SUBTOTAL  = "F3F1EA"

    def build_detailed_pdf(from:, to:, project:, entries:, entries_by_user:, total_seconds:)
      pdf = Prawn::Document.new(page_size: "A4", margin: [40, 40, 50, 40])
      font_dir = Rails.root.join("app/assets/fonts")
      pdf.font_families.update("Inter" => {
        normal: font_dir.join("Inter-Regular.ttf").to_s,
        bold: font_dir.join("Inter-Bold.ttf").to_s
      })
      pdf.font "Inter"

      draw_pdf_title(pdf, project: project, from: from, to: to)
      draw_pdf_summary_cards(pdf, total_seconds: total_seconds, team_size: entries_by_user.size)

      if entries.empty?
        pdf.move_down 24
        pdf.text "No time entries found for this period.", size: 11, color: PDF_MUTED, align: :center
      else
        draw_pdf_team_recap(pdf, entries_by_user: entries_by_user, total_seconds: total_seconds) if entries_by_user.size > 1
        draw_pdf_user_sections(pdf, entries_by_user: entries_by_user, total_seconds: total_seconds, project: project)
      end

      draw_pdf_page_numbers(pdf)
      pdf.render
    end

    def draw_pdf_title(pdf, project:, from:, to:)
      title = project ? "Reports / #{project.name}" : "Detailed Report"
      pdf.text title, size: 20, style: :bold, color: PDF_INK
      pdf.move_down 2
      pdf.text "#{from.strftime('%B %-d, %Y')} – #{to.strftime('%B %-d, %Y')}", size: 10, color: PDF_MUTED
      pdf.move_down 16
    end

    def draw_pdf_summary_cards(pdf, total_seconds:, team_size:)
      gap = 12
      card_w = (pdf.bounds.width - gap) / 2.0
      card_h = 56
      y = pdf.cursor

      [
        { label: "TOTAL HOURS",   value: format_duration_hm(total_seconds) },
        { label: "TEAM MEMBERS",  value: team_size.to_s }
      ].each_with_index do |card, i|
        x = i * (card_w + gap)
        pdf.stroke_color PDF_RULE
        pdf.line_width 0.5
        pdf.stroke_rounded_rectangle [x, y], card_w, card_h, 6
        pdf.fill_color PDF_MUTED
        pdf.draw_text card[:label], at: [x + 14, y - 18], size: 8
        pdf.fill_color PDF_INK
        pdf.font_size(18) { pdf.draw_text card[:value], at: [x + 14, y - 40] }
      end

      pdf.fill_color "000000"
      pdf.stroke_color "000000"
      pdf.move_down card_h + 22
    end

    def draw_pdf_team_recap(pdf, entries_by_user:, total_seconds:)
      pdf.text "Team Overview", size: 12, style: :bold, color: PDF_INK
      pdf.move_down 6

      data = [[ "Team Member", "Hours", "% of Total" ]]
      entries_by_user.each do |user, ents|
        secs = ents.sum(&:duration_seconds)
        pct = total_seconds > 0 ? (secs.to_f / total_seconds * 100).round(1) : 0
        data << [ user.name, format_duration_hm(secs), "#{pct}%" ]
      end

      pdf.table(data, header: true, width: pdf.bounds.width, cell_style: { size: 9, padding: [8, 10], border_color: PDF_RULE, border_width: 0.5 }) do
        row(0).font_style = :bold
        row(0).background_color = PDF_HEADER_BG
        row(0).text_color = PDF_INK
        row(0).size = 8
        column(1).align = :right
        column(2).align = :right
        column(1).font_style = :bold
        rows(1..-1).each_with_index { |row, idx| row.background_color = PDF_STRIPE if idx.odd? }
      end
      pdf.move_down 22
    end

    def draw_pdf_user_sections(pdf, entries_by_user:, total_seconds:, project:)
      show_project = project.nil?

      entries_by_user.each_with_index do |(user, user_entries), idx|
        user_seconds = user_entries.sum(&:duration_seconds)
        user_pct = total_seconds > 0 ? (user_seconds.to_f / total_seconds * 100).round(1) : 0

        # Reserve enough space for header + at least 3 rows; new page otherwise.
        if pdf.cursor < 140 && idx > 0
          pdf.start_new_page
        elsif idx > 0
          pdf.move_down 8
        end

        # User header bar
        header_h = 30
        y = pdf.cursor
        pdf.fill_color PDF_HEADER_BG
        pdf.fill_rectangle [0, y], pdf.bounds.width, header_h
        pdf.fill_color PDF_INK
        pdf.font("Inter", style: :bold) do
          pdf.font_size(12) { pdf.draw_text user.name, at: [12, y - 19] }
          right_text = "#{format_duration_hm(user_seconds)}   #{user_pct}%"
          pdf.font_size(11) do
            tw = pdf.width_of(right_text)
            pdf.draw_text right_text, at: [pdf.bounds.width - tw - 12, y - 19]
          end
        end
        pdf.fill_color "000000"
        pdf.move_down header_h + 4

        # Build single table for this user, all dates.
        headers = [ "Date" ]
        headers << "Project" if show_project
        headers += [ "Task", "Notes", "Time", "Duration" ]

        rows = [ headers ]
        prev_date = nil
        day_total_indexes = []

        by_date = user_entries.group_by { |e| e.started_at.to_date }.sort_by(&:first)

        by_date.each do |date, day_entries|
          day_entries = day_entries.sort_by(&:started_at)
          day_total = day_entries.sum(&:duration_seconds)

          day_entries.each_with_index do |entry, i|
            time_str = "#{entry.started_at.strftime('%H:%M')}–#{entry.stopped_at&.strftime('%H:%M')}"
            date_cell = if i == 0
              "#{date.strftime('%a')}\n#{date.strftime('%b %-d')}"
            else
              ""
            end
            row = [ date_cell ]
            row << entry.project&.name.to_s if show_project
            row << entry.task&.name.to_s
            row << entry.description.to_s
            row << time_str
            row << format_duration_hm(entry.duration_seconds)
            rows << row
          end

          if day_entries.size > 1
            total_row = Array.new(headers.size, "")
            total_row[-2] = "Day total"
            total_row[-1] = format_duration_hm(day_total)
            rows << total_row
            day_total_indexes << (rows.size - 1)
          end
        end

        # Column widths: Date / [Project] / Task / Notes / Time / Duration
        avail = pdf.bounds.width
        widths = if show_project
          [ 55, 95, 75, avail - 55 - 95 - 75 - 80 - 60, 80, 60 ]
        else
          [ 55, 95, avail - 55 - 95 - 80 - 60, 80, 60 ]
        end

        pdf.table(rows, header: true, width: avail, column_widths: widths, cell_style: { size: 8.5, padding: [6, 8], border_color: PDF_RULE, border_width: 0.5, text_color: PDF_INK }) do
          row(0).font_style = :bold
          row(0).background_color = PDF_HEADER_BG
          row(0).size = 7.5
          row(0).text_color = PDF_MUTED
          column(0).font_style = :bold
          column(-1).align = :right
          column(-1).font_style = :bold
          column(-2).align = :center
          column(-2).text_color = PDF_MUTED
          column(-2).size = 7.5

          # Day-total row styling
          day_total_indexes.each do |i|
            row(i).background_color = PDF_SUBTOTAL
            row(i).font_style = :bold
            row(i).size = 8
            row(i).text_color = PDF_MUTED
          end

          # Alternating row stripe for data rows (skip header + day-total rows)
          (1...rows.size).each do |i|
            next if day_total_indexes.include?(i)
            row(i).background_color = PDF_STRIPE if i.odd?
          end
        end
      end
    end

    def draw_pdf_page_numbers(pdf)
      pdf.number_pages "Page <page> of <total>",
                      at: [ 0, -20 ],
                      width: pdf.bounds.width,
                      align: :right,
                      size: 8,
                      color: PDF_FAINT
    end

    def format_duration_hm(seconds)
      return "0h 0m" if seconds.nil? || seconds.zero?
      hours = seconds.to_i / 3600
      minutes = (seconds.to_i % 3600) / 60
      hours > 0 ? "#{hours}h #{minutes}m" : "#{minutes}m"
    end
  end
end
