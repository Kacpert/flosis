require "test_helper"

class ClaudeCliServiceMcpTest < ActiveSupport::TestCase
  # build_command is private; test via send.
  test "includes --mcp-config and --strict-mcp-config when mcp_config given" do
    svc = ClaudeCliService.new(mcp_config: "/srv/proj/.mcp.json")
    cmd = svc.send(:build_command)
    assert_includes cmd, "--mcp-config"
    assert_includes cmd, "/srv/proj/.mcp.json"
    assert_includes cmd, "--strict-mcp-config"
  end

  test "omits mcp flags when mcp_config not given" do
    svc = ClaudeCliService.new
    cmd = svc.send(:build_command)
    assert_not_includes cmd, "--mcp-config"
    assert_not_includes cmd, "--strict-mcp-config"
  end
end
