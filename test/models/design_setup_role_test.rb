require "test_helper"

# A context of the Designs setup. One with no login is built from the app's
# code (Kacper, 2026-11-22: "nie miał credentiali ale może na podstawie repo
# postarać się odzwierciedlić bez otwierania strony").
class DesignSetupRoleTest < ActiveSupport::TestCase
  test "a code-only context needs only its name" do
    project = projects(:jira_project)
    assert DesignSetupRole.new(project: project, name: "Flosis staff", code_only: true).valid?
    refute DesignSetupRole.new(project: project, name: "Admin").valid?
    refute DesignSetupRole.new(project: project, code_only: true).valid?
  end
end
