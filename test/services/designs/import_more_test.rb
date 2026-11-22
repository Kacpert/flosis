require "test_helper"

# Importing more after an import is over (Kacper, 2026-11-22: "żeby po
# wykonaniu, dało się jeszcze doimportować"): a context the person added from
# a suggestion has the map's features it has built again with it, under their
# own keys, so the map stays one row per feature; a fixed login has what was
# built from the code for that context checked against the app.
class Designs::ImportMoreTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @project = projects(:jira_project)
    @first = @project.design_setups.create!(status: "approved", phase: "feature", step: 6, started_by: users(:one), finished_at: 2.days.ago)
    @first.features.create!(name: "Library", key: "library", position: 1, status: "done", contexts: %w[1-admin], screens: [ "Entries" ], brief: "The design library.")
    @first.features.create!(name: "Billing", key: "billing", position: 2, status: "done", contexts: %w[1-admin], screens: [ "Plans" ], brief: "Plans and prices.")
    @import = @project.design_setups.create!(kind: "resync", since_setup: @first, status: "approved", phase: "feature", step: 4, started_by: users(:one),
                                             finished_at: 1.hour.ago, settled_at: 1.hour.ago)
    @billing = @import.features.create!(name: "Billing", key: "billing", position: 1, status: "done", source: "changed", contexts: %w[1-admin],
                                        screens: [ "Plans" ], brief: "Plans and prices.")
    @staff = @project.design_setup_roles.create!(name: "Flosis staff", code_only: true, position: 1)
  end

  def suggestion(features)
    DesignImportSuggestion.record!(@import, kind: "context", title: "Flosis staff sees the Library and Billing", context_name: "Flosis staff", features: features)
  end

  test "a context's map features are queued under their own keys, with the context added" do
    queued = Designs::ImportMore.new(@import).context!(@staff, suggestion(%w[library billing]))

    assert_equal %w[billing library], queued.map(&:key).sort
    @billing.reload
    assert_equal [ "todo", %w[1-admin 2-flosis-staff] ], [ @billing.status, @billing.contexts ]
    library = @import.features.find_by!(key: "library")
    assert_equal [ "Library", "changed", "todo", %w[1-admin 2-flosis-staff], [ "Entries" ], "The design library." ],
                 [ library.name, library.source, library.status, library.contexts, library.screens, library.brief ]
    assert_match(/Flosis staff is a new context: build its screens/, library.reply)
    assert_equal %w[billing library], @project.design_feature_map.map(&:key).sort
    assert_enqueued_with(job: Designs::SetupRunJob, args: [ @import.id ])
  end

  test "without features named, one feature finds the context's screens" do
    feature = Designs::ImportMore.new(@import).context!(@staff, suggestion([])).sole

    assert_equal [ "Flosis staff's screens", %w[2-flosis-staff], "added", "todo" ], [ feature.name, feature.contexts, feature.source, feature.status ]
    assert_includes feature.brief, "Find what Flosis staff has in the app and build its screens."
  end

  test "Fix login queues again what was built from the code for that context" do
    po = @project.design_setup_roles.create!(name: "PO", login_url: "https://s.test/login", username: "po", password: "p", position: 2)
    @billing.update!(from_code: %w[3-po])
    other = @import.features.create!(name: "Designs", key: "designs", position: 2, status: "done", contexts: %w[1-admin])

    assert_equal [ @billing ], Designs::ImportMore.new(@import).fix_login!(po)
    assert_equal "todo", @billing.reload.status
    assert_match(/PO can sign in now/, @billing.reply)
    assert_equal "done", other.reload.status
  end
end
