require "net/http"
require "json"

# Checks an EU VAT number in the European Commission's VIES: an EU business
# needs a valid one for a reverse-charge invoice (consumers can't buy). Never
# raises: VIES being down is a result the form can say plainly.
module Billing
  module Vies
    TIMEOUT = 10
    URL = "https://ec.europa.eu/taxation_customs/vies/rest-api/ms/%s/vat/%s".freeze

    Result = Data.define(:valid, :name, :error) do
      def valid? = valid
      def unavailable? = error.present?
    end

    module_function

    # country_code is ISO (GR for Greece, which VIES calls EL); number may
    # carry its country prefix.
    def check(country_code, number)
      code = country_code.to_s.upcase == "GR" ? "EL" : country_code.to_s.upcase
      digits = number.to_s.upcase.gsub(/[^A-Z0-9]/, "").delete_prefix(code)
      uri = URI(format(URL, code, digits))
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: TIMEOUT, read_timeout: TIMEOUT) do |http|
        http.get(uri.request_uri, "Accept" => "application/json")
      end
      return unavailable("VIES answered #{response.code}") unless response.is_a?(Net::HTTPSuccess)

      body = JSON.parse(response.body)
      if body["isValid"]
        Result.new(valid: true, name: body["name"].presence&.then { |name| name == "---" ? nil : name }, error: nil)
      elsif body["userError"].to_s.in?(%w[INVALID VALID]) || body["userError"].blank?
        Result.new(valid: false, name: nil, error: nil)
      else
        unavailable("VIES: #{body['userError']}")
      end
    rescue StandardError => e
      Rails.logger.warn("[Billing::Vies] #{e.class}: #{e.message}")
      unavailable("VIES could not be reached")
    end

    def unavailable(message)
      Result.new(valid: false, name: nil, error: message)
    end
  end
end
