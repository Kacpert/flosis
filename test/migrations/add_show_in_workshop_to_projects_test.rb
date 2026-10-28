require "test_helper"
require Rails.root.join("db/migrate/20261028160000_add_show_in_workshop_to_projects")

# Thirteen projects existed on production when this shipped and exactly one of
# them — the only one with a board, a repository or a ticket — was a Workshop
# project. The rest were Time & HR stubs. The migration has to tell them apart
# from evidence, because nobody is going to tick twelve boxes.
class AddShowInWorkshopToProjectsTest < ActiveSupport::TestCase
  setup do
    Project.update_all(show_in_workshop: false)
    @jira = projects(:jira_project)
    @stub = projects(:hr_only_project)
    @plain = projects(:plain_project)
    [ @jira, @stub, @plain ].each { |p| p.update_columns(github_repo: nil, jira_site: nil) }
    @plain.update_columns(external_type: nil, external_reference: nil)
    @stub.update_columns(external_type: nil, external_reference: nil)
  end

  test "a project with a Jira board belongs in the Workshop" do
    AddShowInWorkshopToProjects.new.up

    assert @jira.reload.show_in_workshop
  end

  test "a project with only hours against it does not" do
    assert_equal 0, Task.where(project: @stub).count, "fixture drifted: this stub must have no tickets"

    AddShowInWorkshopToProjects.new.up

    assert_not @stub.reload.show_in_workshop
  end

  test "a repository is enough on its own, with no Jira at all" do
    @plain.update_columns(github_repo: "acme/widgets")

    AddShowInWorkshopToProjects.new.up

    assert @plain.reload.show_in_workshop, "someone reviews PRs here, so it is a Workshop project"
  end

  test "Jira credentials without a project key are still enough" do
    @plain.update_columns(jira_site: "https://acme.atlassian.net")

    AddShowInWorkshopToProjects.new.up

    assert @plain.reload.show_in_workshop
  end

  test "a ticket is enough even with no integration left configured" do
    Task.create!(project: @plain, name: "Leftover", external_reference: "OLD-1")

    AddShowInWorkshopToProjects.new.up

    assert @plain.reload.show_in_workshop, "work was done here once; hiding it would lose the board"
  end

  # The role backfill gave every employee holding Workshop access a Project
  # Manager row on EVERY project in their workspace, stubs included. Reading
  # that as evidence would have kept all thirteen and fixed nothing.
  test "a membership granting everything is NOT evidence" do
    ProjectMembership.create!(
      user: users(:one), project: @stub, **PermissionPreset::PERMISSIONS.index_with(true)
    )

    AddShowInWorkshopToProjects.new.up

    assert_not @stub.reload.show_in_workshop
  end
end
