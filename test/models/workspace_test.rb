require "test_helper"

class WorkspaceTest < ActiveSupport::TestCase
  test "clients feature is disabled by default for a new workspace" do
    workspace = Workspace.create!(name: "Fresh Co")
    assert_not workspace.clients_enabled?, "new workspaces should default to clients disabled"
  end

  test "github settings default to nil/false" do
    w = Workspace.create!(name: "GH Co")
    assert_nil w.github_token
    assert_nil w.github_repo
    assert_not w.pr_review_enabled
    assert_nil w.github_status_ok
  end

  test "estimation_field_names defaults to AI estimation when nil" do
    w = Workspace.create!(name: "Estimation Co")
    assert_equal ["AI estimation"], w.estimation_field_names
  end

  test "estimation_field_names returns the stored value when present" do
    w = Workspace.create!(name: "Estimation Co", estimation_field_names: ["Custom field"])
    assert_equal ["Custom field"], w.estimation_field_names
  end

  # On MySQL (production) a :json column can come back from the driver as a
  # raw JSON *string* rather than a parsed Array, unlike PostgreSQL (dev/test).
  # The reader normalizes via #normalize_field_names so the views
  # ("names - ESTIMATION_FIELD_OPTIONS", "names.each") don't 500 with
  # "undefined method '-'/'each' for a String".
  test "normalize_field_names parses a raw JSON array string (MySQL) into an Array" do
    w = Workspace.new(name: "Estimation Co")
    result = w.send(:normalize_field_names, %q(["AI estimation", "Custom"]))

    assert_kind_of Array, result
    assert_equal ["AI estimation", "Custom"], result
    # The exact operations the views perform must not raise on the result:
    assert_nothing_raised do
      result - Workspace::ESTIMATION_FIELD_OPTIONS
      result.each { |n| n }
    end
  end

  test "normalize_field_names handles already-parsed Arrays (PostgreSQL)" do
    w = Workspace.new(name: "Estimation Co")
    assert_equal ["A", "B"], w.send(:normalize_field_names, ["A", "B"])
  end

  test "normalize_field_names falls back to the default for nil / blank string / empty array" do
    w = Workspace.new(name: "Estimation Co")
    assert_equal ["AI estimation"], w.send(:normalize_field_names, nil)
    assert_equal ["AI estimation"], w.send(:normalize_field_names, "")
    assert_equal ["AI estimation"], w.send(:normalize_field_names, "[]")
    assert_equal ["AI estimation"], w.send(:normalize_field_names, [])
  end

  test "normalize_field_names tolerates a malformed JSON string without raising" do
    w = Workspace.new(name: "Estimation Co")
    assert_nothing_raised do
      # A non-JSON string should be wrapped, not crash the page.
      assert_kind_of Array, w.send(:normalize_field_names, "not json")
    end
  end

  test "estimation_trigger defaults to manual" do
    w = Workspace.create!(name: "Estimation Co")
    assert_equal "manual", w.estimation_trigger
  end

  test "estimation_status_trigger defaults to Ready for dev" do
    w = Workspace.create!(name: "Estimation Co")
    assert_equal "Ready for dev", w.estimation_status_trigger
  end
end
