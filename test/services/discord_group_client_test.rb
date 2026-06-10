require "test_helper"
require "webmock/minitest"

class DiscordGroupClientTest < ActiveSupport::TestCase
  def client
    DiscordGroupClient.new(token: "tok-123", channel_id: "999")
  end

  test "configured? is false when token or channel missing" do
    assert_not DiscordGroupClient.new(token: nil, channel_id: "999").configured?
    assert_not DiscordGroupClient.new(token: "x", channel_id: nil).configured?
    assert client.configured?
  end

  test "post sends the message and returns true on 200" do
    stub = stub_request(:post, "https://discord.com/api/v10/channels/999/messages")
      .with(
        headers: { "Authorization" => "tok-123", "Content-Type" => "application/json" },
        body: { content: "hello" }.to_json
      )
      .to_return(status: 200, body: { id: "1" }.to_json)

    assert client.post("hello")
    assert_requested stub
  end

  test "post returns false on a non-2xx response without raising" do
    stub_request(:post, "https://discord.com/api/v10/channels/999/messages")
      .to_return(status: 500, body: "nope")
    assert_not client.post("hello")
  end

  test "post returns false on a network error without raising" do
    stub_request(:post, "https://discord.com/api/v10/channels/999/messages")
      .to_raise(SocketError.new("boom"))
    assert_not client.post("hello")
  end
end
