require "prawn"
require "prawn/table"

# One closed month's usage statement (SCRUM-71): each project and its price,
# and the organization's total. A breakdown of AI spend, not a tax invoice:
# no number and no VAT.
class UsageStatementPdf
  def initialize(workspace, month)
    @workspace = workspace
    @month = month.beginning_of_month
    @summary = AiCosts.new(workspace).month(@month)
  end

  def render
    pdf = Prawn::Document.new(page_size: "A4", margin: 48, info: { Title: "Usage statement #{@month.strftime('%B %Y')}", Creator: "Flosis" })
    dir = Rails.root.join("app/assets/fonts")
    pdf.font_families.update("Inter" => { normal: dir.join("Inter-Regular.ttf").to_s, bold: dir.join("Inter-Bold.ttf").to_s })
    pdf.font "Inter"
    pdf.font_size 9.5

    pdf.text "Usage statement · #{@month.strftime('%B %Y')}", size: 18, style: :bold
    pdf.text @workspace.name, size: 11
    pdf.move_down 4
    pdf.text "Every AI run in #{@workspace.name}, all projects, priced as it ran. A breakdown, not a tax invoice.", color: "666666"
    pdf.move_down 16

    rows = [ [ "Project", "Runs", "Price" ] ]
    @summary.by_project.each { |name, runs, amount, _priced| rows << [ name, runs.to_s, money(amount) ] }
    rows << [ "Total", @summary.runs.to_s, money(@summary.total) ]
    pdf.table(rows, width: pdf.bounds.width, header: true, cell_style: { borders: [ :bottom ], border_color: "DDDDDD", padding: [ 6, 4 ] }) do
      row(0).font_style = :bold
      row(0).text_color = "666666"
      row(-1).font_style = :bold
      columns(1..2).align = :right
    end
    if @summary.unknown_runs.positive?
      pdf.move_down 10
      pdf.text "#{@summary.unknown_runs} run(s) came back with no cost and are not in these figures.", color: "666666"
    end
    if @summary.own_key_total.to_d.positive?
      pdf.text "Runs on a project's own Anthropic key: #{money(@summary.own_key_total)}, not counted here.", color: "666666"
    end
    pdf.render
  end

  private

  def money(amount) = Billing::Copy.money(amount)
end
