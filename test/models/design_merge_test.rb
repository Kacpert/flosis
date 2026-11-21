require "test_helper"

class DesignMergeTest < ActiveSupport::TestCase
  # An acceptance (2026-11-21) remembers its accepted copy and the
  # description version it wrote, with what that version changed.
  test "a merge keeps its accepted copy, the version it wrote and what changed in it" do
    task = tasks(:jira_task)
    merge = DesignMerge.create!(project: task.project, task: task, sha: "a" * 40, title: "t", branch: "design/x",
                                how: "manual", merged_at: Time.current, slot: "accepted/7", description_version: 5,
                                description_changes: [ "a", "b" ])
    merge.reload

    assert_equal [ "accepted/7", 5, [ "a", "b" ], false, nil ],
                 [ merge.slot, merge.description_version, merge.description_changes, merge.described_fallback, merge.announced_at ]
    assert_includes task.design_merges, merge
  end
end
