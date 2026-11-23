require "prawn"
require "prawn/table"
require "rqrcode"

# The PDF of one invoice (SCRUM-71), emailed to every admin once KSeF has its
# number: seller and buyer, the line, net, VAT (also in PLN at the NBP rate),
# the gross, how it was paid, and the KSeF number under the KOD I QR code,
# which is how customers abroad, who can't open KSeF, check it.
class InvoicePdf
  def initialize(invoice)
    @invoice = invoice
  end

  def render
    pdf = Prawn::Document.new(page_size: "A4", margin: 48, info: { Title: "Invoice #{@invoice.number}", Creator: "Flosis" })
    fonts(pdf)
    head(pdf)
    parties(pdf)
    lines(pdf)
    totals(pdf)
    notes(pdf)
    ksef(pdf)
    pdf.render
  end

  private

  def money(amount) = Billing::Copy.money(amount)

  def fonts(pdf)
    dir = Rails.root.join("app/assets/fonts")
    pdf.font_families.update("Inter" => { normal: dir.join("Inter-Regular.ttf").to_s, bold: dir.join("Inter-Bold.ttf").to_s })
    pdf.font "Inter"
    pdf.font_size 9.5
  end

  def head(pdf)
    pdf.text "Invoice #{@invoice.number}", size: 18, style: :bold
    pdf.text "Faktura VAT", size: 10, color: "666666"
    pdf.move_down 8
    pdf.text "Issued #{date(@invoice.issued_on)} · Sold #{date(@invoice.sold_on)} · Currency USD", color: "444444"
    pdf.move_down 18
  end

  def parties(pdf)
    seller = Billing::Seller
    left = [ "SELLER", seller.name.to_s, seller.street.to_s, "#{seller.postal_code} #{seller.city}", "Poland", "NIP #{seller.nip}" ]
    right = [ "BUYER", @invoice.buyer_name, @invoice.buyer_street.to_s, [ @invoice.buyer_postal_code, @invoice.buyer_city ].compact.join(" "),
              Billing::Countries.name(@invoice.buyer_country_code), buyer_number ].compact
    top = pdf.cursor
    [ [ left, 0 ], [ right, pdf.bounds.width / 2 + 10 ] ].each do |rows, x|
      pdf.bounding_box([ x, top ], width: pdf.bounds.width / 2 - 10) do
        pdf.text rows.first, size: 8, style: :bold, color: "888888"
        pdf.move_down 3
        pdf.text rows[1], style: :bold
        rows.drop(2).reject(&:blank?).each { |row| pdf.text row }
      end
    end
    pdf.move_cursor_to top - 92
  end

  def buyer_number
    number = @invoice.buyer_vat_number
    return nil if number.blank?

    case @invoice.vat_treatment
    when "pl_23" then "NIP #{number.delete_prefix('PL')}"
    when "eu_reverse_charge" then "EU VAT #{number}"
    else "Tax ID #{number}"
    end
  end

  def lines(pdf)
    rate = @invoice.vat_usd.positive? ? "#{@invoice.vat_rate.to_i}%" : (@invoice.vat_treatment == "eu_reverse_charge" ? "np II" : "np I")
    rows = [ [ "Item", "Qty", "Net", "VAT rate", "VAT", "Gross" ],
             [ @invoice.line_name, "1", money(@invoice.net_usd), rate, money(@invoice.vat_usd), money(@invoice.gross_usd) ] ]
    pdf.table(rows, width: pdf.bounds.width, header: true,
                    cell_style: { borders: [ :bottom ], border_color: "DDDDDD", padding: [ 6, 4 ] }) do
      row(0).font_style = :bold
      row(0).text_color = "666666"
      columns(1..5).align = :right
    end
    pdf.move_down 14
  end

  def totals(pdf)
    rows = [ [ "Net", money(@invoice.net_usd) ],
             [ @invoice.vat_usd.positive? ? "VAT #{@invoice.vat_rate.to_i}%" : "VAT", money(@invoice.vat_usd) ],
             [ "Total", money(@invoice.gross_usd) ] ]
    pdf.table(rows, position: :right, width: 220, cell_style: { borders: [], padding: [ 3, 4 ] }) do
      columns(1).align = :right
      row(2).font_style = :bold
      row(2).size = 11
    end
    if @invoice.vat_pln_line
      pdf.move_down 4
      pdf.text "VAT in PLN: #{@invoice.vat_pln_line} (table #{@invoice.exchange_rate_table}).", align: :right, size: 8.5, color: "444444"
    end
    pdf.move_down 16
  end

  def notes(pdf)
    paid = @invoice.billing_charge.succeeded_at&.in_time_zone&.to_date || @invoice.issued_on
    card = @invoice.workspace.billing_account&.card_short
    pdf.text "Paid in full by card#{" (#{card})" if card} on #{date(paid)}. Zapłacono kartą.", color: "444444"
    case @invoice.vat_treatment
    when "eu_reverse_charge"
      pdf.text "Reverse charge: VAT is accounted for by the buyer (odwrotne obciążenie, art. 28b and 100 ust. 1 pkt 4 of the Polish VAT Act; art. 196 of Directive 2006/112/EC).", color: "444444"
    when "non_eu"
      pdf.text "Not subject to Polish VAT: the service is supplied outside Poland (art. 28b of the Polish VAT Act, np.).", color: "444444"
    end
    pdf.move_down 18
  end

  def ksef(pdf)
    return pdf.text("Not sent to KSeF yet.", color: "AA0000") unless @invoice.ksef_number && @invoice.qr_url

    qr = RQRCode::QRCode.new(@invoice.qr_url, level: :m)
    png = qr.as_png(size: 360, border_modules: 2)
    top = pdf.cursor
    pdf.image StringIO.new(png.to_s), width: 110, at: [ 0, top ]
    pdf.bounding_box([ 0, top - 112 ], width: 200) { pdf.text @invoice.ksef_number, size: 7.5 }
    pdf.bounding_box([ 130, top ], width: pdf.bounds.width - 130) do
      pdf.text "KSeF number", size: 8, style: :bold, color: "888888"
      pdf.text @invoice.ksef_number, style: :bold
      pdf.move_down 6
      pdf.text "This invoice is in Poland's National e-Invoice System (KSeF). Scan the code, or open the link, to check it:", color: "444444"
      pdf.text @invoice.qr_url, size: 7.5, color: "1A56DB"
    end
  end

  def date(day) = day.strftime("%-d %b %Y")
end
