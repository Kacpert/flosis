require "test_helper"

# The estimation settings moved from the workspace onto the project, and the
# release that dropped the workspace's columns took EstimationSettings off
# Workspace with them. These cases were written against Workspace and are kept
# here, against the model that now owns the columns — the MySQL case below is
# a production 500 that must not be allowed back.
class ProjectEstimationSettingsTest < ActiveSupport::TestCase
  def project(**attributes)
    workspaces(:one).projects.create!(name: "Estimation Co", color: "#123456", **attributes)
  end

  test "estimation_field_names defaults to AI estimation when nil" do
    assert_equal [ "AI estimation" ], project.estimation_field_names
  end

  test "estimation_field_names returns the stored value when present" do
    assert_equal [ "Custom field" ], project(estimation_field_names: [ "Custom field" ]).estimation_field_names
  end

  # On MySQL (production) a :json column can come back from the driver as a
  # raw JSON *string* rather than a parsed Array, unlike PostgreSQL (dev/test).
  # The reader normalizes via #normalize_field_names so the views
  # ("names - ESTIMATION_FIELD_OPTIONS", "names.each") don't 500 with
  # "undefined method '-'/'each' for a String".
  test "normalize_field_names parses a raw JSON array string (MySQL) into an Array" do
    result = Project.new.send(:normalize_field_names, %q(["AI estimation", "Custom"]))

    assert_kind_of Array, result
    assert_equal [ "AI estimation", "Custom" ], result
    # The exact operations the views perform must not raise on the result:
    assert_nothing_raised do
      result - EstimationSettings::ESTIMATION_FIELD_OPTIONS
      result.each { |n| n }
    end
  end

  test "normalize_field_names handles already-parsed Arrays (PostgreSQL)" do
    assert_equal [ "A", "B" ], Project.new.send(:normalize_field_names, [ "A", "B" ])
  end

  test "normalize_field_names falls back to the default for nil / blank string / empty array" do
    p = Project.new
    assert_equal [ "AI estimation" ], p.send(:normalize_field_names, nil)
    assert_equal [ "AI estimation" ], p.send(:normalize_field_names, "")
    assert_equal [ "AI estimation" ], p.send(:normalize_field_names, "[]")
    assert_equal [ "AI estimation" ], p.send(:normalize_field_names, [])
  end

  test "normalize_field_names tolerates a malformed JSON string without raising" do
    assert_nothing_raised do
      # A non-JSON string should be wrapped, not crash the page.
      assert_kind_of Array, Project.new.send(:normalize_field_names, "not json")
    end
  end

  test "estimation_trigger defaults to manual" do
    assert_equal "manual", project.estimation_trigger
  end

  test "estimation_status_trigger defaults to Ready for dev" do
    assert_equal "Ready for dev", project.estimation_status_trigger
  end

  # The columns the workspace used to carry are gone from it entirely; a
  # project is now the only place they exist.
  test "the workspace no longer answers for estimation at all" do
    assert_not Workspace.new.respond_to?(:estimation_field_names),
               "the workspace kept an estimation reader after its columns were dropped"
  end
end
