require "test_helper"

# What a task's accepted designs are (2026-11-21), read from the accepted copy
# its newest acceptance published: the Designs section, the task's file, the
# modal and Jira's links all list these.
class Designs::AcceptedScreensTest < ActiveSupport::TestCase
  setup do
    @root = Pathname(Dir.mktmpdir("preview"))
    ENV["DESIGNS_PREVIEW_ROOT"] = @root.to_s
    @task = tasks(:jira_task)
    @project = @task.project
    @project.update!(design_preview_token: "t0k")
  end

  teardown do
    ENV.delete("DESIGNS_PREVIEW_ROOT")
    FileUtils.remove_entry(@root)
  end

  def merge!(sha, slot: nil, at: Time.current, screens: [])
    DesignMerge.create!(project: @project, task: @task, sha: sha * 40, title: "t", branch: "design/x", how: "manual",
                        merged_at: at, slot: slot, screens: screens)
  end

  def publish(slot)
    folder = @root.join("t0k", slot, "__flosis")
    FileUtils.mkdir_p(folder)
    File.write(folder.join("screens.json"), {
      contexts: [ { id: "admin", name: "Admin" } ],
      screens: [ { id: "consumption", context: "admin", name: "Consumption — this month" },
                 { id: "bugs", context: "admin", name: "Bug Reporting" } ]
    }.to_json)
    File.write(folder.join("changes.json"), {
      own: [ [ "admin", "consumption", "new" ], [ "admin", "bugs", "updated" ] ],
      through: { "sidebar" => [ [ "admin", "x" ] ] }
    }.to_json)
  end

  test "the newest published acceptance gives the screens, their names and kinds" do
    first = merge!("a", slot: "accepted/7", at: 2.days.ago)
    second = merge!("b", slot: "accepted/7", at: 1.day.ago)
    publish("accepted/7")
    accepted = Designs::AcceptedScreens.new(@task)

    assert accepted.any?
    assert_equal "accepted/7", accepted.slot
    assert_equal [ first, second ], accepted.merges
    assert_equal({ context: "admin", context_name: "Admin", screen: "consumption", name: "Consumption — this month", kind: "new" },
                 accepted.own.first)
    assert_equal [ "bugs", "updated" ], accepted.own.last.values_at(:screen, :kind)
    assert_equal [ "sidebar" ], accepted.through_names
  end

  test "a merge whose copy was never published, or that has none, does not count" do
    merge!("a")
    merge!("b", slot: "accepted/9")
    accepted = Designs::AcceptedScreens.new(@task)

    assert_not accepted.any?
    assert_nil accepted.slot
    assert_equal [], accepted.own
  end
end
