require "test_helper"

# Creating a project is the one place several decisions land at once: the keys
# it starts with, and who is in it. Keys are COPIED, not linked — see the spec.
# Rotating a token therefore means visiting each project, which is the price of
# deleting a project never becoming a question about another project's keys.
class ProjectCreatorTest < ActiveSupport::TestCase
  setup do
    @workspace = workspaces(:one)
    @source = projects(:jira_project)
    @source.update!(jira_site: "acme.atlassian.net", jira_email: "e@x.com", jira_api_token: "jt",
                    github_repo: "acme/source", github_token: "gt", anthropic_api_key: "ak")
  end

  def create(reuse_from: {}, member_ids: [], preset: "Project Manager")
    ProjectCreator.new(
      workspace: @workspace,
      attributes: { name: "Partner Portal", team: "Apps team", github_repo: "acme/partner-portal" },
      reuse_from: reuse_from, member_ids: member_ids, preset: preset
    ).call
  end

  # Marking every new project "jira" would make the Jira chip claim a connection
  # it does not have, have the health check call Jira for it, and let the daily
  # features scan write a codebase summary onto it.
  test "a project is only a Jira project when it was given Jira credentials" do
    assert_nil create.external_type
    assert_equal "jira", create(reuse_from: { "jira" => @source.id }).external_type
  end

  test "copies the chosen keys and leaves the rest blank" do
    project = create(reuse_from: { "jira" => @source.id, "ai" => @source.id })

    assert_equal "acme.atlassian.net", project.jira_site
    assert_equal "jt", project.jira_api_token
    assert_equal "ak", project.anthropic_api_key
    assert_nil project.github_token, "GitHub was set to be configured later"
  end

  test "the form's own repository wins over the copied one" do
    project = create(reuse_from: { "github" => @source.id })

    assert_equal "acme/partner-portal", project.github_repo
    assert_equal "gt", project.github_token
  end

  test "a source project in another workspace is ignored" do
    outsider = Project.create!(name: "Foreign", workspace: workspaces(:two), color: "#3B82F6",
                               jira_api_token: "secret")

    project = create(reuse_from: { "jira" => outsider.id })

    assert_nil project.jira_api_token
  end

  test "chosen people are added with the preset" do
    project = create(member_ids: [ users(:two).id ], preset: "Product Owner")
    membership = project.project_memberships.find_by(user: users(:two))

    assert_equal "Product Owner", membership.role_label
  end

  # `color` is validated present and hex-formatted and the dialog never asks for
  # one, so without this the very first create raises RecordInvalid.
  test "a project gets a colour nobody else in the workspace is using" do
    project = create

    assert_match(/\A#[0-9A-Fa-f]{6}\z/, project.color)
    assert_not_includes @workspace.projects.where.not(id: project.id).pluck(:color), project.color
  end

  test "someone outside the workspace is not added" do
    outsider = User.create!(name: "Outsider", email_address: "out@example.com",
                            password: "x" * 12, password_confirmation: "x" * 12)

    project = create(member_ids: [ outsider.id ])

    assert_empty project.project_memberships.where(user: outsider)
  end
end
