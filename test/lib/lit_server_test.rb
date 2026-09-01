require "test_helper"
require "webmock/minitest"
require Rails.root.join("lib/mcp/lit_server")

# The point of this server is that it is NARROW: the automation gets the two
# calls it needs and no way to reach anything else. These tests hold that line —
# the alternative was granting Bash, which would put SECRET_KEY_BASE and the
# database password within reach of a prompt.
class LitServerTest < ActiveSupport::TestCase
  ENV_STUB = { "LIT_AI_API_KEY" => "secret-key", "LIT_API_BASE" => "https://lit.test" }.freeze

  # Drives the server over stdio the way the Claude CLI does and returns the
  # parsed replies.
  def exchange(*messages, env: ENV_STUB)
    input = StringIO.new(messages.map { |m| JSON.generate(m) }.join("\n") + "\n")
    output = StringIO.new
    Lit::Server.new(input: input, output: output, env: env).run
    output.string.lines.map { |l| JSON.parse(l) }
  end

  def call(name, args = {}, env: ENV_STUB)
    exchange({ jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: name, arguments: args } }, env: env).first
  end

  def result_text(response) = response.dig("result", "content", 0, "text")
  def error?(response) = response.dig("result", "isError") == true

  def suggestion(key: "talent.export", locale: "da", value: "Eksport", tags: [ "DEV-111 talent export" ])
    { "key" => key, "locale" => locale, "value" => value, "tags" => tags }
  end

  # ---- protocol ----------------------------------------------------------

  test "handshake reports the tools it offers" do
    responses = exchange(
      { jsonrpc: "2.0", id: 1, method: "initialize", params: {} },
      { jsonrpc: "2.0", method: "notifications/initialized" },
      { jsonrpc: "2.0", id: 2, method: "tools/list", params: {} }
    )

    assert_equal 2, responses.size, "a notification must not get a reply"
    assert_equal "lit", responses.first.dig("result", "serverInfo", "name")
    assert_equal %w[post_suggestions refresh_keys], responses.last.dig("result", "tools").map { |t| t["name"] }
  end

  test "an unknown tool is refused" do
    assert error?(call("delete_everything"))
    assert_match(/Unknown tool/, result_text(call("delete_everything")))
  end

  test "malformed input does not kill the server" do
    input = StringIO.new("not json\n" + JSON.generate({ jsonrpc: "2.0", id: 7, method: "ping" }) + "\n")
    output = StringIO.new
    Lit::Server.new(input: input, output: output, env: ENV_STUB).run

    assert_equal 7, JSON.parse(output.string.lines.last)["id"], "the server kept going after a bad line"
  end

  # ---- posting suggestions ------------------------------------------------

  test "posts suggestions to Lit and returns its verdict" do
    stub_request(:post, "https://lit.test/lit/api/v1/ai/suggestions")
      .with(
        headers: { "Authorization" => 'Token token="secret-key"', "Content-Type" => "application/json" },
        body: { provider: "claude", suggestions: [ suggestion ] }
      )
      .to_return(status: 200, body: { "talent.export" => "created" }.to_json)

    response = call("post_suggestions", { "suggestions" => [ suggestion ] })

    assert_not error?(response)
    assert_match(/created/, result_text(response))
  end

  test "refresh_keys hits its own endpoint" do
    stub_request(:post, "https://lit.test/lit/api/v1/ai/refresh_keys")
      .to_return(status: 200, body: "{}")

    assert_not error?(call("refresh_keys"))
  end

  test "a failing Lit call is reported, not swallowed" do
    stub_request(:post, "https://lit.test/lit/api/v1/ai/suggestions")
      .to_return(status: 422, body: "unknown locale")

    response = call("post_suggestions", { "suggestions" => [ suggestion ] })

    assert error?(response)
    assert_match(/422/, result_text(response))
    assert_match(/unknown locale/, result_text(response))
  end

  test "a network failure is reported as a tool error" do
    stub_request(:post, "https://lit.test/lit/api/v1/ai/suggestions").to_timeout

    assert error?(call("post_suggestions", { "suggestions" => [ suggestion ] }))
  end

  # ---- the guardrails -----------------------------------------------------

  test "the API key never appears in a tool result" do
    stub_request(:post, "https://lit.test/lit/api/v1/ai/suggestions")
      .to_return(status: 500, body: "boom")

    response = call("post_suggestions", { "suggestions" => [ suggestion ] })

    assert_not_includes response.to_json, "secret-key", "the key must never reach the transcript"
  end

  test "refuses to post when no key is configured" do
    response = call("post_suggestions", { "suggestions" => [ suggestion ] },
                    env: { "LIT_API_BASE" => "https://lit.test" })

    assert error?(response)
    assert_match(/LIT_AI_API_KEY is not set/, result_text(response))
  end

  test "the model cannot choose the host or path" do
    stub_request(:post, "https://lit.test/lit/api/v1/ai/suggestions").to_return(status: 200, body: "{}")

    # Arguments that look like an attempt to redirect the call are simply not
    # part of the schema — they must be rejected as unsupported fields.
    response = call("post_suggestions", {
      "suggestions" => [ suggestion.merge("url" => "https://evil.test/steal") ],
      "url" => "https://evil.test/steal"
    })

    assert error?(response)
    assert_match(/unsupported fields: url/, result_text(response))
    assert_not_requested :post, "https://evil.test/steal"
  end

  test "rejects a batch over the documented limit" do
    response = call("post_suggestions", { "suggestions" => Array.new(501) { suggestion } })

    assert error?(response)
    assert_match(/exceeds the 500 limit/, result_text(response))
  end

  test "rejects suggestions missing required fields" do
    response = call("post_suggestions", { "suggestions" => [ { "key" => "a.b", "locale" => "da" } ] })

    assert error?(response)
    assert_match(/missing value/, result_text(response))
  end

  test "rejects a malformed tags list" do
    response = call("post_suggestions", { "suggestions" => [ suggestion(tags: "DEV-111") ] })

    assert error?(response)
    assert_match(/tags must be an array/, result_text(response))
  end

  test "an empty batch is refused rather than posted" do
    response = call("post_suggestions", { "suggestions" => [] })

    assert error?(response)
    assert_not_requested :post, "https://lit.test/lit/api/v1/ai/suggestions"
  end
end
