require "test_helper"
require "open3"

# The setup's browser tools (lib/designs_crawler: the sign-in and the MCP
# browser) are Node, with tests of their own; run here, the suite covers them.
# Without Node or the folder's packages this skips, and the browser test skips
# itself where Chromium cannot start.
class DesignsBrowserTest < ActiveSupport::TestCase
  DIR = Rails.root.join("lib/designs_crawler")

  test "the browser tools pass their own tests" do
    skip "Node is not installed" unless system("node", "--version", out: File::NULL, err: File::NULL)
    skip "Run npm install in lib/designs_crawler first" unless DIR.join("node_modules/@modelcontextprotocol/sdk").directory?

    out, status = Open3.capture2e("node", "--test", *Dir.glob(DIR.join("test/*.test.mjs").to_s), chdir: DIR.to_s)
    assert status.success?, out.lines.last(40).join
    assert_match(/^# fail 0$/, out)
  end
end
