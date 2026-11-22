require "test_helper"

# What an import leaves for the person (Kacper, 2026-11-22: "jak AI nie miało
# danej roli czy coś"): one suggestion per thing, and one the person
# dismissed is not raised again by a later import.
class DesignImportSuggestionTest < ActiveSupport::TestCase
  setup do
    @project = projects(:jira_project)
    @import = @project.design_setups.create!(kind: "resync", status: "active", phase: "resync", started_by: users(:one))
  end

  test "record! keeps one suggestion per thing" do
    first = DesignImportSuggestion.record!(@import, kind: "context", title: "Flosis staff can see the Library", context_name: "Flosis staff", features: [ "library" ])
    again = DesignImportSuggestion.record!(@import, kind: "context", title: "Flosis staff again", context_name: "Flosis staff")

    assert_equal first, again
    assert_equal [ "Flosis staff can see the Library", [ "library" ] ], [ again.title, again.features ]
    assert_equal 1, @import.suggestions.count
  end

  test "a sign-in suggestion is keyed by its context" do
    role = @project.design_setup_roles.create!(name: "Admin", login_url: "https://s.test/login", username: "a", password: "p", position: 0)
    DesignImportSuggestion.record!(@import, kind: "sign_in", title: "Admin could not sign in", role: role)
    DesignImportSuggestion.record!(@import, kind: "sign_in", title: "Admin could not sign in", detail: "Again.", role: role)

    assert_equal [ "sign_in:#{role.id}" ], @import.suggestions.pluck(:key)
  end

  test "a dismissed suggestion stays dismissed in later imports" do
    DesignImportSuggestion.record!(@import, kind: "context", title: "Super admin", context_name: "Super admin").update!(status: "dismissed")
    later = @project.design_setups.create!(kind: "resync", status: "active", phase: "resync", started_by: users(:one))

    assert_nil DesignImportSuggestion.record!(later, kind: "context", title: "Super admin again", context_name: "Super admin")
    assert_equal [ "Super admin" ], DesignImportSuggestion.dismissed_contexts(@project)
  end
end
