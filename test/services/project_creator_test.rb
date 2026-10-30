require "test_helper"

# Creating a project is the one place several decisions land at once: the keys
# it starts with, and who is in it. Keys are COPIED, not linked — see the spec.
# Rotating a token therefore means visiting each project, which is the price of
# deleting a project never becoming a question about another project's keys.
class ProjectCreatorTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @workspace = workspaces(:one)
    @source = projects(:jira_project)
    @source.update!(jira_site: "acme.atlassian.net", jira_email: "e@x.com", jira_api_token: "jt",
                    github_repo: "acme/source", github_token: "gt", anthropic_api_key: "ak",
                    jira_story_points_field_id: "customfield_1", jira_ai_estimation_field_id: "customfield_2",
                    jira_ai_actions_field_id: "customfield_3")
  end

  def create(reuse_from: {}, member_ids: [], preset: "Project Manager", **extra)
    ProjectCreator.new(
      workspace: @workspace,
      attributes: { name: "Partner Portal", team: "Apps team",
                    github_repo: "acme/partner-portal", **extra },
      reuse_from: reuse_from, member_ids: member_ids, preset: preset
    ).call
  end

  # Marking every new project "jira" would make the Jira chip claim a connection
  # it does not have, have the health check call Jira for it, and let the daily
  # features scan write a codebase summary onto it.
  #
  # Credentials alone are not enough either: without a project key the sync
  # calls Jira with nil and dies on every run, the health check still succeeds
  # so the chip goes green, and the Tasks board offers a project that can never
  # return a ticket.
  test "a project is only a Jira project when it has both the credentials and a key" do
    assert_nil create.external_type
    assert_nil create(reuse_from: { "jira" => @source.id }).external_type
    assert_nil create(external_reference: "PP").external_type

    assert_equal "jira", create(reuse_from: { "jira" => @source.id }, external_reference: "PP").external_type
  end

  # The custom field ids are a property of the Jira SITE, so a project reusing
  # that site's credentials already knows them — re-resolving them on first use
  # leaves AI estimation and story-point mirroring unconfigured until someone
  # presses "Verify fields".
  test "reusing Jira brings the site's cached custom field ids along" do
    project = create(reuse_from: { "jira" => @source.id })

    assert_equal "customfield_1", project.jira_story_points_field_id
    assert_equal "customfield_2", project.jira_ai_estimation_field_id
    assert_equal "customfield_3", project.jira_ai_actions_field_id
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

  # The dialog is the one place that can hand a project a repository and a
  # GitHub key together. Such a project is configured from birth, so saving the
  # GitHub card would never start its checkout.
  test "a project created with GitHub keys queues a checkout of its repo" do
    project = create(reuse_from: { "github" => @source.id })

    assert_enqueued_jobs 1, only: ProjectRepoCheckoutJob
    assert_enqueued_with(job: ProjectRepoCheckoutJob, args: [ project.id ])
  end

  # Both halves count, as they do when the GitHub card is saved: a repository
  # with no key, or a key with no repository, has nothing to clone yet.
  test "a project created without GitHub keys queues no checkout" do
    assert_no_enqueued_jobs(only: ProjectRepoCheckoutJob) do
      create
      create(github_repo: nil, reuse_from: { "github" => @source.id })
    end
  end

  # The checkout is for a project that exists, so it is queued only once the
  # create has gone through, memberships included.
  test "a create that fails queues no checkout" do
    original = ProjectMembership.instance_method(:save!)
    ProjectMembership.define_method(:save!) { raise ActiveRecord::RecordInvalid, self }

    assert_no_enqueued_jobs(only: ProjectRepoCheckoutJob) do
      assert_raises(ActiveRecord::RecordInvalid) do
        create(reuse_from: { "github" => @source.id }, member_ids: [ users(:two).id ])
      end
    end
  ensure
    ProjectMembership.define_method(:save!, original)
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

  # `color` carries a NOT NULL database default, so nothing raises without this
  # — every project created through the dialog would simply come out the same
  # blue as the one next to it, which is the one thing the colour is for.
  test "a project gets a colour nobody else in the workspace is using" do
    project = create

    assert_match(/\A#[0-9A-Fa-f]{6}\z/, project.color)
    assert_not_includes @workspace.projects.where.not(id: project.id).pluck(:color), project.color
  end

  # The rule the Users grid enforces on create, update and destroy, and which
  # lived only in the dialog's own `where.not`: a row for a workspace admin
  # holds nothing while the flag is on, hands over whatever the preset granted
  # the day it comes off, and destroy refuses to delete it in the meantime.
  test "a workspace admin is not given a row" do
    admin = users(:one)
    assert admin.workspace_admin?(@workspace), "fixture precondition"

    project = create(member_ids: [ admin.id ], preset: "Administrator")

    assert_empty project.project_memberships.where(user: admin)
  end

  # save! and then add_members, outside a transaction, left the project behind
  # while the caller was told the create had failed.
  test "a project is not left behind when a membership cannot be saved" do
    original = ProjectMembership.instance_method(:save!)
    ProjectMembership.define_method(:save!) { raise ActiveRecord::RecordInvalid, self }

    assert_no_difference "Project.count" do
      assert_raises(ActiveRecord::RecordInvalid) { create(member_ids: [ users(:two).id ]) }
    end
  ensure
    ProjectMembership.define_method(:save!, original)
  end

  test "someone outside the workspace is not added" do
    outsider = User.create!(name: "Outsider", email_address: "out@example.com",
                            password: "x" * 12, password_confirmation: "x" * 12)

    project = create(member_ids: [ outsider.id ])

    assert_empty project.project_memberships.where(user: outsider)
  end
end
