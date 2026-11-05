require "test_helper"

# An import (Designs imports): what its page and the Imports line say about it,
# which of its features need the person, and who has opened it since it
# settled.
class DesignSetupImportsTest < ActiveSupport::TestCase
  LIMIT = "Claude stopped with an error: You've hit your session limit · resets 8am (Europe/Warsaw)".freeze

  setup do
    @project = projects(:jira_project)
    @project.update!(design_app_url: "https://app.flosis.com")
    finished = Time.zone.local(2026, 11, 3, 6, 50)
    @first = DesignSetup.create!(project: @project, started_by: users(:one), status: "approved", created_at: Time.zone.local(2026, 11, 3, 1, 40),
                                 finished_at: finished, settled_at: finished)
  end

  def feature(setup, name, status, **more)
    setup.features.create!(name: name, key: name.parameterize, position: setup.features.maximum(:position).to_i + 1, status: status, **more)
  end

  def resync
    DesignSetup.create!(project: @project, kind: "resync", since_setup: @first, started_by: users(:one))
  end

  test "a first import's title names the app's host" do
    assert_equal "First import · from app.flosis.com", @first.title
    assert @first.first?
  end

  test "a resync's title names the import it starts from" do
    assert_equal "Changes since Nov 3", resync.title
  end

  test "summary counts what was built" do
    6.times { |i| feature(@first, "Built #{i}", "done") }
    5.times { |i| feature(@first, "Failed #{i}", "failed") }
    assert_equal "6 of 11 features built", @first.summary
    feature(@first, "Not wanted", "set_aside")
    assert_equal "6 of 11 features built", @first.summary, "a feature set aside is not counted"

    changes = resync
    3.times { |i| feature(changes, "Changed #{i}", "done", source: "changed") }
    feature(changes, "New one", "done", source: "new")
    feature(changes, "Proposed", "review", source: "changed")
    assert_equal "3 updated · 1 new", changes.summary
  end

  test "needs you is the waiting, review, failed and paused features, not those set aside" do
    feature(@first, "Done", "done")
    feature(@first, "Waiting", "waiting", question: "Connect Jira?")
    feature(@first, "Review", "review")
    feature(@first, "Failed", "failed", error: "Failed to parse Claude response")
    feature(@first, "Paused", "todo", resets_at: 1.hour.from_now)
    feature(@first, "Queued", "todo")
    feature(@first, "Aside", "set_aside")
    assert_equal %w[Waiting Review Failed Paused], @first.needs_you.map(&:name)
  end

  test "the line is lit until the person opens the import, and again once it settles" do
    assert @first.lit_for?(users(:one))
    assert DesignSetup.lit_for?(@project, users(:one))
    @first.seen_by!(users(:one))
    refute @first.lit_for?(users(:one))
    refute DesignSetup.lit_for?(@project, users(:one))
    assert @first.lit_for?(users(:two)), "each person has their own"
    travel 1.minute do
      @first.settle!
      assert @first.lit_for?(users(:one)), "a batch that settles lights it again"
    end
    refute DesignSetup.create!(project: @project, status: "active").lit_for?(users(:one)), "a running import has not settled"
  end

  test "an import is busy while a feature waits in its queue" do
    refute @first.busy?
    feature(@first, "Queued", "todo", queued_at: Time.current)
    assert @first.busy?
    assert DesignSetup.create!(project: @project, status: "active").busy?
  end

  test "a feature's problem comes from what happened" do
    features = [ feature(@first, "Limit", "failed", error: LIMIT), feature(@first, "Unreadable", "failed", error: "Failed to parse Claude response"),
                 feature(@first, "Other", "failed", error: "Claude stopped with an error: overloaded"),
                 feature(@first, "Waiting", "waiting", question: "Connect Jira?"), feature(@first, "Review", "review"),
                 feature(@first, "Paused", "todo", resets_at: 1.hour.from_now), feature(@first, "Done", "done") ]
    assert_equal [ :limit, :unreadable, :error, :waiting, :review, :paused, nil ], features.map(&:problem)
  end

  test "queue! clears the last attempt and keeps the branch only to go on" do
    failed = feature(@first, "Failed", "failed", error: "boom", attempts: 2, branch: "wip/import-1-failed", finished_at: Time.current,
                     question: "?", notes: [ "No reports in the test data.", "Could not finish: boom" ])
    travel_to Time.zone.local(2026, 11, 4, 9, 0) do
      failed.queue!(reply: "Use the admin account")
    end
    assert_equal [ "todo", nil, 0, nil, nil, "Use the admin account", nil ],
                 [ failed.status, failed.error, failed.attempts, failed.branch, failed.finished_at, failed.reply, failed.question ]
    assert_equal Time.zone.local(2026, 11, 4, 9, 0), failed.queued_at
    assert_equal [ "No reports in the test data." ], failed.notes

    waiting = feature(@first, "Waiting", "waiting", question: "Connect Jira?", branch: "wip/import-1-waiting")
    waiting.queue!(reply: "Connected it", fresh: false)
    assert_equal [ "todo", "wip/import-1-waiting", "Connect Jira?", "Connected it" ], [ waiting.status, waiting.branch, waiting.question, waiting.reply ]
  end

  test "an import's merge says so" do
    assert_equal "Flosis AI · import", DesignMerge.new(how: "import").how_label
  end

  test "a re-import whose thread is deleted, or gone for good, has nothing to retry" do
    thread = @project.design_threads.create!(author: users(:one), title: "Re-import from staging", branch: "design/re-import-from-staging")
    setup = DesignSetup.create!(project: @project, kind: "reimport", status: "failed", started_by: users(:one), design_thread: thread)
    assert_not setup.thread_deleted?

    thread.update!(status: "deleted", deleted_at: Time.current)
    assert setup.reload.thread_deleted?

    thread.destroy!
    assert setup.reload.thread_deleted?
  end
end
