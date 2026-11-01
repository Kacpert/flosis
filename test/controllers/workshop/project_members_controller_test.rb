require "test_helper"

# The switches are the product. Everything else on this screen is a reading of
# them, so the endpoint that flips one has to be exact about who may call it.
class Workshop::ProjectMembersControllerTest < ActionDispatch::IntegrationTest
  setup do
    @workspace = workspaces(:one)
    @workspace.update!(workshop_enabled: true)
    @project = projects(:jira_project)
    @membership = project_memberships(:two_elvium)
    workspace_memberships(:one_owner).update!(workspace_admin: true)
    sign_in_as(users(:one))
    post switch_product_path, params: { product: "workshop" }
    post switch_workshop_project_path, params: { project_id: @project.id }
  end

  test "flipping a switch saves it and reports the new role name" do
    @membership.update!(PermissionPreset.attributes_for("Project Manager").merge(designs: true))

    patch workshop_project_member_path(@membership),
          params: { permission: "briefing_config", value: "1" }, as: :turbo_stream

    assert_response :success
    assert @membership.reload.briefing_config
    assert_equal "Product Owner", @membership.role_label
  end

  test "an unknown switch is refused" do
    patch workshop_project_member_path(@membership),
          params: { permission: "launch_missiles", value: "1" }, as: :turbo_stream

    assert_response :unprocessable_entity
  end

  test "someone without Configuration cannot flip anyone's switches" do
    workspace_memberships(:one_owner).update!(workspace_admin: false)
    project_memberships(:one_elvium).update!(PermissionPreset.attributes_for("Project Manager"))

    patch workshop_project_member_path(@membership),
          params: { permission: "configuration", value: "1" }, as: :turbo_stream

    assert_response :redirect
    assert_not @membership.reload.configuration
  end

  test "removing a member takes away the project, not the account" do
    assert_difference "ProjectMembership.count", -1 do
      assert_no_difference "User.count" do
        delete workshop_project_member_path(@membership)
      end
    end
  end

  test "a workspace admin cannot be removed from a project" do
    admin_membership = project_memberships(:one_elvium)

    assert_no_difference "ProjectMembership.count" do
      delete workshop_project_member_path(admin_membership)
    end
  end

  test "inviting an unknown address creates the account and the membership" do
    assert_difference [ "User.count", "ProjectMembership.count" ], 1 do
      post workshop_project_members_path, params: {
        name: "Dana Liu", email_address: "dana@acme.io", preset: "Product Owner"
      }
    end

    membership = ProjectMembership.joins(:user).find_by(users: { email_address: "dana@acme.io" })
    assert_equal "Product Owner", membership.role_label
    assert_not membership.user.can_access_time_hr?(workspaces(:one)),
               "a Workshop invitation must not hand out an HR account"
  end

  # The dialog says "add" and offers a preset, so running it over somebody who
  # is already here would re-grade all six of their switches under a toast that
  # claims they were added. client_user is Tasks and nothing else; the preset
  # below would hand them four permissions.
  test "inviting someone already on the project changes nothing and says where permissions live" do
    membership = project_memberships(:client_elvium)
    before = membership.attributes.slice(*PermissionPreset::PERMISSIONS.map(&:to_s))

    assert_no_difference [ "User.count", "ProjectMembership.count" ] do
      post workshop_project_members_path, params: {
        name: "Whatever", email_address: users(:client_user).email_address, preset: "Administrator"
      }
    end

    assert_equal before, membership.reload.attributes.slice(*PermissionPreset::PERMISSIONS.map(&:to_s)),
                 "an invitation must not re-grade a switch"
    assert_match(/Client Person is already on Elvium/, flash[:alert])
    assert_match(/grid/, flash[:alert], "the refusal has to say where permissions are edited")
    assert_no_enqueued_emails
  end

  # welcome carries a week-long edit_password_url, so it is only ever for an
  # account that has no password yet — see WorkspaceMembersController#create,
  # which picks between the two mailers the same way.
  test "a brand-new address is sent the mail that sets a password" do
    post workshop_project_members_path, params: {
      name: "Dana Liu", email_address: "dana@acme.io", preset: "Product Owner"
    }

    assert_enqueued_emails 1
    assert_enqueued_email_with InvitationMailer, :welcome,
                               args: [ User.find_by!(email_address: "dana@acme.io"), @workspace ]
  end

  test "an address that already has an account is told it was added, not asked for a password" do
    outsider = User.create!(name: "Ida Berg", email_address: "ida@acme.io",
                            password: "password", password_confirmation: "password")

    assert_difference "WorkspaceMembership.count", 1 do
      post workshop_project_members_path, params: {
        name: "Ida Berg", email_address: outsider.email_address, preset: "Project Manager"
      }
    end

    assert_enqueued_emails 1
    assert_enqueued_email_with InvitationMailer, :added_to_workspace, args: [ outsider, @workspace ]
  end

  test "someone already in this workspace joins the project with no mail at all" do
    insider = User.create!(name: "Ola Nilsen", email_address: "ola@acme.io",
                           password: "password", password_confirmation: "password")
    @workspace.workspace_memberships.create!(user: insider, time_hr_access: true, workspace_admin: false)

    assert_difference "ProjectMembership.count", 1 do
      post workshop_project_members_path, params: {
        name: insider.name, email_address: insider.email_address, preset: "Project Manager"
      }
    end

    assert_no_enqueued_emails
  end

  test "adding people from another project applies the chosen preset" do
    project_memberships(:client_elvium).destroy!

    post workshop_project_members_path, params: {
      user_ids: [ users(:client_user).id ], preset: "Project Manager"
    }

    membership = ProjectMembership.find_by(user: users(:client_user), project: projects(:jira_project))
    assert_equal "Project Manager", membership.role_label
  end

  # A row for an administrator holds nothing — the flag already grants all six —
  # and destroy refuses to remove it, so a mistaken add could not be undone from
  # the interface at all.
  test "a workspace admin cannot be given a project membership" do
    project_memberships(:one_elvium).destroy!

    assert_no_difference "ProjectMembership.count" do
      post workshop_project_members_path, params: {
        user_ids: [ users(:one).id ], preset: "Administrator"
      }
    end

    assert_equal "An administrator's access does not come from this project.", flash[:alert]
  end

  # The second submit of one dialog used to race the unique index into a 500.
  test "submitting the add dialog twice refuses the second rather than raising" do
    project_memberships(:client_elvium).destroy!
    params = { user_ids: [ users(:client_user).id ], preset: "Project Manager" }

    post workshop_project_members_path, params: params

    assert_no_difference "ProjectMembership.count" do
      post workshop_project_members_path, params: params
    end

    assert_match(/already on Elvium/, flash[:alert])
  end

  # destroy refuses an administrator's row; update used to write to it, storing
  # a value that is ignored while the flag is set and takes effect the day it is
  # removed. The grid renders those switches disabled, so this is the hand-rolled
  # POST and nothing else.
  test "a workspace admin's switches cannot be flipped either" do
    admin_membership = project_memberships(:one_elvium)

    patch workshop_project_member_path(admin_membership),
          params: { permission: "pricing", value: "0" }, as: :turbo_stream

    assert_response :redirect
    assert admin_membership.reload.pricing, "the stored value must be left exactly as it was"
  end
end
