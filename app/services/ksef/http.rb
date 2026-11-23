require "net/http"
require "json"

module Ksef
  # A thin Net::HTTP wrapper for the KSeF API: JSON in and out, bearer tokens,
  # timeouts, and KSeF's error bodies (both its "problem details" and the
  # older "exception" shape) turned into a short Ksef::ApiError. Network
  # failures become Ksef::TransportError. Tokens only ever go into the
  # Authorization header — never into a message or a log line.
  class Http
    OPEN_TIMEOUT = 10
    READ_TIMEOUT = 30

    attr_reader :base_url

    def initialize(base_url, open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT)
      @base_url = base_url.chomp("/")
      @open_timeout = open_timeout
      @read_timeout = read_timeout
    end

    def get(path, token: nil)
      request(Net::HTTP::Get, path, token: token)
    end

    def post_json(path, body = nil, token: nil)
      request(Net::HTTP::Post, path, token: token, body: body&.to_json, content_type: "application/json")
    end

    def post_xml(path, xml, token: nil)
      request(Net::HTTP::Post, path, token: token, body: xml, content_type: "application/xml")
    end

    private

    def request(verb, path, token:, body: nil, content_type: nil)
      uri = URI("#{base_url}#{path}")
      req = verb.new(uri)
      req["Accept"] = "application/json"
      req["X-Error-Format"] = "problem-details"
      req["User-Agent"] = "Flosis"
      req["Authorization"] = "Bearer #{token}" if token
      if body
        req["Content-Type"] = content_type
        req.body = body
      end

      response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                                 open_timeout: @open_timeout, read_timeout: @read_timeout) do |http|
        http.request(req)
      end
      handle(response)
    rescue Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout, SocketError, SystemCallError,
           OpenSSL::SSL::SSLError, IOError, EOFError => e
      raise TransportError, "KSeF unreachable (#{e.class.name.demodulize})"
    end

    def handle(response)
      status = response.code.to_i
      json = parse(response.body)
      return json if status.between?(200, 299)

      raise error_from(status, json)
    end

    def parse(body)
      return nil if body.blank?

      JSON.parse(body)
    rescue JSON::ParserError
      nil
    end

    # Problem details: { title, detail, errors: [{ code, description, details }] }
    # Old shape:       { exception: { exceptionDetailList: [{ exceptionCode, exceptionDescription, details }] } }
    # 429:             { status: { code, description, details } }
    def error_from(status, json)
      json = {} unless json.is_a?(Hash)
      first = Array(json["errors"]).first
      first ||= Array(json.dig("exception", "exceptionDetailList")).first&.then do |e|
        { "code" => e["exceptionCode"], "description" => e["exceptionDescription"], "details" => e["details"] }
      end
      first ||= json["status"] if json["status"].is_a?(Hash)
      first ||= {}

      ApiError.new(
        http_status: status,
        code: first["code"],
        description: first["description"].presence || json["detail"].presence || json["title"].presence,
        details: Array(first["details"]).map(&:to_s)
      )
    end
  end
end
