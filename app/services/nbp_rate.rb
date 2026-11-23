require "net/http"
require "json"

# The National Bank of Poland's mid rate for the US dollar (table A) from the
# last working day before a date: a USD invoice shows its VAT in PLN at that
# rate (art. 31a of the VAT act). Raises NbpRate::Unavailable when NBP can't
# say, so the caller retries rather than invoices with no rate.
module NbpRate
  class Unavailable < StandardError; end

  TIMEOUT = 10
  URL = "https://api.nbp.pl/api/exchangerates/rates/a/usd/%s/%s/?format=json".freeze

  Rate = Data.define(:mid, :date, :table)

  module_function

  def usd_before(date)
    uri = URI(format(URL, (date - 10).iso8601, (date - 1).iso8601))
    response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: TIMEOUT, read_timeout: TIMEOUT) do |http|
      http.get(uri.request_uri, "Accept" => "application/json")
    end
    raise Unavailable, "NBP answered #{response.code}" unless response.is_a?(Net::HTTPSuccess)

    last = JSON.parse(response.body).fetch("rates").max_by { |rate| rate["effectiveDate"] }
    raise Unavailable, "NBP has no USD rate before #{date}" unless last

    Rate.new(mid: BigDecimal(last["mid"].to_s), date: Date.iso8601(last["effectiveDate"]), table: last["no"])
  rescue Unavailable
    raise
  rescue StandardError => e
    raise Unavailable, "NBP could not be reached (#{e.class})"
  end
end
