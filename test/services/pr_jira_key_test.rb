require "test_helper"

class PrJiraKeyTest < ActiveSupport::TestCase
  test "extracts an uppercase key from branch, title, or body" do
    assert_equal "DEV-836", PrJiraKey.extract(branch: "feature/DEV-836-thing", title: "x", body: "")
    assert_equal "DEV-836", PrJiraKey.extract(branch: "x", title: "DEV-836 add stuff", body: "")
    assert_equal "DEV-836", PrJiraKey.extract(branch: "x", title: "y", body: "fixes DEV-836")
  end

  test "is case-insensitive and upcases the result" do
    assert_equal "DEV-836", PrJiraKey.extract(branch: "dev-836-thing", title: "", body: "")
  end

  test "returns nil when no key present" do
    assert_nil PrJiraKey.extract(branch: "feature/cleanup", title: "tidy", body: "no ticket")
  end
end
