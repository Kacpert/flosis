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

  # github/github-mcp-server folded get_pull_request and get_pull_request_files
  # into pull_request_read. In -p mode a tool that isn't on --allowedTools is
  # simply refused, so a stale name here disables the tool silently — exactly
  # the failure that made an automation fall back to probing PR numbers by hand.
  test "the GitHub automation tools use github-mcp-server's own names" do
    tools = ClaudeCliService::AUTOMATION_TOOLS

    assert_includes tools, "mcp__github__pull_request_read"
    assert_includes tools, "mcp__github__list_pull_requests"
    assert_includes tools, "mcp__github__list_commits"
    assert_not_includes tools, "mcp__github__get_pull_request"
    assert_not_includes tools, "mcp__github__get_pull_request_files"
  end

  test "automations may read GitHub but never write to it" do
    writes = %w[create_pull_request merge_pull_request delete_file create_or_update_file push_files
                update_pull_request create_branch fork_repository]

    writes.each do |tool|
      assert_not_includes ClaudeCliService::AUTOMATION_TOOLS, "mcp__github__#{tool}"
    end
  end

  test "omits mcp flags when mcp_config not given" do
    svc = ClaudeCliService.new
    cmd = svc.send(:build_command)
    assert_not_includes cmd, "--mcp-config"
    assert_not_includes cmd, "--strict-mcp-config"
  end
end
