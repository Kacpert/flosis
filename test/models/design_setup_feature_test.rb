require "test_helper"

# One feature of a setup run's map (the Designs setup, feature by feature):
# what its row on the progress screen says, and the key it is known by.
class DesignSetupFeatureTest < ActiveSupport::TestCase
  setup { @setup = DesignSetup.create!(project: projects(:jira_project), started_by: users(:one)) }

  def feature(**attributes)
    n = @setup.features.count + 1
    @setup.features.create!({ position: n, key: "feature-#{n}", name: "Feature #{n}" }.merge(attributes))
  end

  test "the label follows the status and the notes" do
    assert_equal "Matches the app", feature(status: "done").label
    assert_equal "Done · 1 note", feature(status: "done", notes: [ "No pending requests in the test data." ]).label
    assert_equal "Done · 2 notes", feature(status: "done", notes: %w[one two]).label
    assert_equal "Building", feature(status: "running", stage: "building").label
    assert_equal "Checking against the app", feature(status: "running", stage: "checking").label
    assert_equal "Up next", feature.label(up_next: true)
    assert_equal "To do", feature.label
    assert_equal "Couldn't finish", feature(status: "failed").label
  end

  test "keys stay unique and are never empty" do
    assert_equal "timesheet", DesignSetupFeature.key_for("Timesheet", [])
    assert_equal "timesheet-2", DesignSetupFeature.key_for("Timesheet", %w[timesheet])
    assert_equal "timesheet-3", DesignSetupFeature.key_for("Timesheet", %w[timesheet timesheet-2])
    assert_equal "feature", DesignSetupFeature.key_for("!!!", [])
  end

  test "a finished feature knows how long it took" do
    done = feature(status: "done", started_at: 38.minutes.ago, finished_at: Time.current)
    assert_in_delta 38 * 60, done.duration, 2
    assert_nil feature.duration
  end

  test "statuses and stages are checked" do
    assert_not @setup.features.new(position: 9, key: "x", name: "X", status: "later").valid?
    assert_not @setup.features.new(position: 9, key: "x", name: "X", stage: "dreaming").valid?
  end
end
