#!/usr/bin/env ruby
# frozen_string_literal: true

# A deliberately narrow MCP server for the Lit translation API.
#
# WHY THIS EXISTS
# The i18n automation has to POST its proposed translations to Lit. The only
# generic tools that can make a POST are Bash and a full HTTP client, and
# granting either to an automation hands the prompt the app's whole
# environment — SECRET_KEY_BASE, the database password, every token dotenv
# loads. So instead of widening the blast radius, this exposes exactly the two
# calls that automation needs and nothing else:
#
#   - the URL is built here from LIT_API_BASE; the model cannot choose a host
#   - LIT_AI_API_KEY is read from this process's env and never appears in a
#     tool's arguments or in its result, so it can't leak into a transcript
#   - the payload is validated field by field; anything unrecognised is refused
#
# Deliberately Rails-free: it starts in milliseconds, needs no database, and a
# bug in it cannot touch application state.
#
# Speaks MCP over stdio (JSON-RPC 2.0, one message per line), which is all the
# Claude CLI needs — no SDK.

require "json"
require "net/http"
require "uri"

module Lit
  class Server
    PROTOCOL_VERSION = "2025-06-18"
    SERVER_INFO = { "name" => "lit", "version" => "1.0.0" }.freeze

    # Lit's own documented ceiling. Enforced here as well so a runaway prompt
    # can't fire a 50k-item request at it.
    MAX_SUGGESTIONS = 500
    # Every field a suggestion may carry; anything else is a mistake worth
    # reporting rather than silently forwarding.
    SUGGESTION_FIELDS = %w[key locale value tags].freeze
    REQUIRED_FIELDS = %w[key locale value].freeze
    HTTP_TIMEOUT = 30

    def initialize(input: $stdin, output: $stdout, env: ENV)
      @input = input
      @output = output
      @api_key = env["LIT_AI_API_KEY"].to_s
      @base = env.fetch("LIT_API_BASE", "https://pre-prod.elvium.com").to_s.chomp("/")
    end

    def run
      while (line = @input.gets)
        line = line.strip
        next if line.empty?

        message = begin
          JSON.parse(line)
        rescue JSON::ParserError
          next
        end

        response = handle(message)
        next if response.nil? # notification — no reply

        @output.puts(JSON.generate(response))
        @output.flush
      end
    end

    private

    def handle(message)
      id = message["id"]
      # A notification (no id) never gets a reply.
      return nil if id.nil?

      case message["method"]
      when "initialize"  then ok(id, initialize_result)
      when "tools/list"  then ok(id, { "tools" => tools })
      when "tools/call"  then ok(id, call_tool(message["params"] || {}))
      when "ping"        then ok(id, {})
      else
        error(id, -32_601, "Unknown method: #{message['method']}")
      end
    rescue StandardError => e
      # Never die on one bad message: the automation should see the failure as a
      # tool result and carry on with the rest of its work.
      error(message["id"], -32_603, "#{e.class}: #{e.message}")
    end

    def initialize_result
      {
        "protocolVersion" => PROTOCOL_VERSION,
        "capabilities" => { "tools" => {} },
        "serverInfo" => SERVER_INFO,
        "instructions" => "Posts AI translation suggestions to Lit. Suggestions are proposals: " \
                          "a human accepts them in Lit, nothing goes live automatically."
      }
    end

    def tools
      [
        {
          "name" => "post_suggestions",
          "description" => "Post translation suggestions to Lit (max #{MAX_SUGGESTIONS} per call). " \
                           "Returns Lit's own per-key verdict: created, updated, kept_human_edit or " \
                           "unknown_key. Nothing goes live until a person accepts it in Lit.",
          "inputSchema" => {
            "type" => "object",
            "required" => [ "suggestions" ],
            "properties" => {
              "suggestions" => {
                "type" => "array",
                "maxItems" => MAX_SUGGESTIONS,
                "items" => {
                  "type" => "object",
                  "required" => REQUIRED_FIELDS,
                  "properties" => {
                    "key" => { "type" => "string", "description" => "The i18n key path, e.g. talent.profile.export" },
                    "locale" => { "type" => "string", "description" => "Target locale, e.g. da or sv" },
                    "value" => { "type" => "string", "description" => "The translated string" },
                    "tags" => {
                      "type" => "array", "items" => { "type" => "string" },
                      "description" => "Jira key plus a short feature name, e.g. DEV-111 talent profile export"
                    }
                  }
                }
              }
            }
          }
        },
        {
          "name" => "refresh_keys",
          "description" => "Ask Lit to re-scan the codebase for i18n keys. Call once after finishing a task, " \
                           "so keys that only exist inline become known to Lit.",
          "inputSchema" => { "type" => "object", "properties" => {} }
        }
      ]
    end

    def call_tool(params)
      name = params["name"]
      args = params["arguments"] || {}

      case name
      when "post_suggestions" then post_suggestions(args)
      when "refresh_keys"     then post("/lit/api/v1/ai/refresh_keys", {})
      else tool_error("Unknown tool: #{name}")
      end
    end

    def post_suggestions(args)
      suggestions = args["suggestions"]
      return tool_error("suggestions must be an array") unless suggestions.is_a?(Array)
      return tool_error("suggestions is empty — nothing to post") if suggestions.empty?
      if suggestions.size > MAX_SUGGESTIONS
        return tool_error("#{suggestions.size} suggestions exceeds the #{MAX_SUGGESTIONS} limit — split into batches")
      end

      problems = suggestions.each_with_index.flat_map { |s, i| validate(s, i) }
      return tool_error(problems.join("; ")) if problems.any?

      post("/lit/api/v1/ai/suggestions", { "provider" => "claude", "suggestions" => suggestions })
    end

    def validate(suggestion, index)
      return [ "suggestion #{index} is not an object" ] unless suggestion.is_a?(Hash)

      problems = []
      missing = REQUIRED_FIELDS.reject { |f| suggestion[f].is_a?(String) && !suggestion[f].empty? }
      problems << "suggestion #{index} is missing #{missing.join(', ')}" if missing.any?

      unknown = suggestion.keys - SUGGESTION_FIELDS
      problems << "suggestion #{index} has unsupported fields: #{unknown.join(', ')}" if unknown.any?

      tags = suggestion["tags"]
      unless tags.nil? || (tags.is_a?(Array) && tags.all?(String))
        problems << "suggestion #{index}: tags must be an array of strings"
      end

      problems
    end

    # The only place that talks to Lit. The host comes from LIT_API_BASE and the
    # path from the caller's tool name — never from the model.
    def post(path, body)
      return tool_error("LIT_AI_API_KEY is not set on the server") if @api_key.empty?

      uri = URI.join("#{@base}/", path.delete_prefix("/"))
      request = Net::HTTP::Post.new(uri)
      request["Authorization"] = %(Token token="#{@api_key}")
      request["Content-Type"] = "application/json"
      request["Accept"] = "application/json"
      request.body = JSON.generate(body)

      response = Net::HTTP.start(uri.host, uri.port,
                                 use_ssl: uri.scheme == "https",
                                 open_timeout: HTTP_TIMEOUT, read_timeout: HTTP_TIMEOUT) do |http|
        http.request(request)
      end

      text = "HTTP #{response.code}\n#{response.body}"
      response.is_a?(Net::HTTPSuccess) ? tool_result(text) : tool_error(text)
    rescue StandardError => e
      tool_error("Request to Lit failed: #{e.class}: #{e.message}")
    end

    def tool_result(text)
      { "content" => [ { "type" => "text", "text" => text } ] }
    end

    # An isError result (rather than a JSON-RPC error) so the model reads the
    # reason and can correct itself instead of just seeing "tool failed".
    def tool_error(text)
      tool_result(text).merge("isError" => true)
    end

    def ok(id, result)
      { "jsonrpc" => "2.0", "id" => id, "result" => result }
    end

    def error(id, code, message)
      { "jsonrpc" => "2.0", "id" => id, "error" => { "code" => code, "message" => message } }
    end
  end
end

Lit::Server.new.run if $PROGRAM_NAME == __FILE__
