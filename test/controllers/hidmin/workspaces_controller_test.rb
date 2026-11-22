require "test_helper"

class Hidmin::WorkspacesControllerTest < ActionDispatch::IntegrationTest
  setup do
    users(:one).update!(flosis_staff: true)
    sign_in_as(users(:one))
  end

  test "creating an organization makes its first administrator and emails them" do
    assert_difference -> { Workspace.count } => 1, -> { User.count } => 1 do
      post hidmin_workspaces_path, params: {
        workspace: { name: "Acme", workshop_enabled: "1", clients_enabled: "0" },
        admin: { name: "Jane Doe", email_address: "jane@acme.com", time_hr_access: "0" }
      }
    end

    workspace = Workspace.find_by!(name: "Acme")
    jane = User.find_by!(email_address: "jane@acme.com")
    assert_redirected_to hidmin_workspace_path(workspace)
    assert workspace.workshop_enabled?
    assert_not workspace.hr_access?, "a new organization starts without Time & HR"
    assert jane.workspace_admin?(workspace)
    assert_not jane.can_access_time_hr?(workspace)
    assert_enqueued_email_with InvitationMailer, :welcome, args: [ jane, workspace ]
  end

  test "an existing account can be made the administrator of a new organization" do
    post hidmin_workspaces_path, params: {
      workspace: { name: "Acme" }, admin: { name: "", email_address: users(:two).email_address }
    }

    workspace = Workspace.find_by!(name: "Acme")
    assert users(:two).workspace_admin?(workspace)
    assert_enqueued_email_with InvitationMailer, :added_to_workspace, args: [ users(:two), workspace ]
  end

  test "a bad administrator address creates no organization" do
    assert_no_difference [ "Workspace.count", "User.count", "WorkspaceMembership.count" ] do
      post hidmin_workspaces_path, params: { workspace: { name: "Acme" }, admin: { name: "Jane", email_address: "nope" } }
    end

    assert_response :unprocessable_entity
    assert_no_enqueued_emails
  end

  test "a blank name creates nothing either" do
    assert_no_difference [ "Workspace.count", "User.count" ] do
      post hidmin_workspaces_path, params: { workspace: { name: "" }, admin: { name: "Jane", email_address: "jane@acme.com" } }
    end

    assert_response :unprocessable_entity
  end

  test "settings are saved" do
    patch hidmin_workspace_path(workspaces(:two)),
          params: { workspace: { name: "Renamed", workshop_enabled: "1", hr_access: "0", clients_enabled: "1" } }

    assert_redirected_to hidmin_workspace_path(workspaces(:two))
    workspaces(:two).reload
    assert_equal "Renamed", workspaces(:two).name
    assert workspaces(:two).workshop_enabled?
    assert_not workspaces(:two).hr_access?
    assert workspaces(:two).clients_enabled?
  end

  test "an organization's Time & HR can be switched on" do
    workspaces(:two).update!(hr_access: false)

    patch hidmin_workspace_path(workspaces(:two)), params: { workspace: { hr_access: "1" } }

    assert workspaces(:two).reload.hr_access?
  end

  # -- SCRUM-70: billing ------------------------------------------------

  def billed_run!(workspace: workspaces(:one), cost:, margin: 30, own_key: false, area: "pr_reviews", project: projects(:jira_project), **rest)
    price = cost && (own_key ? cost : (BigDecimal(cost.to_s) * (1 + BigDecimal(margin.to_s) / 100)).round(6))
    AiRun.create!({ workspace: workspace, project: project, project_name: project&.name, area: area, automation: "PR review",
                    status: "succeeded", ran_at: Time.current, own_key: own_key, cost_usd: cost,
                    margin_percent: (own_key ? nil : margin), price_usd: price, model: "claude-opus-5",
                    item_label: "#19 Designs" }.merge(rest))
  end

  test "organizations list shows cost, price and the margin" do
    workspaces(:one).update!(ai_plan: ai_plans(:scale))
    billed_run!(cost: 100)
    billed_run!(cost: nil)

    get hidmin_workspaces_path
    row = css_select("[data-organization-row='#{workspaces(:one).id}']").text.squish
    assert_includes row, "Scale · $1,200.00"
    assert_includes row, "30%"
    assert_includes row, "$100.00"
    assert_includes row, "$130.00"
    assert_includes row, "11% of the limit"
    assert_includes row, "1 UNKNOWN"
  end

  test "an organization without a plan is offered one to assign" do
    get hidmin_workspaces_path
    row = css_select("[data-organization-row='#{workspaces(:two).id}']")
    assert_select row, "select[name=ai_plan_id] option", text: "Scale"
    assert_includes row.text, "no plan"
  end

  test "assigning a plan sets this month's limit" do
    patch assign_plan_hidmin_workspace_path(workspaces(:two)), params: { ai_plan_id: ai_plans(:scale).id }
    assert_redirected_to hidmin_workspaces_path
    workspace = workspaces(:two).reload
    assert_equal ai_plans(:scale), workspace.ai_plan
    assert workspace.ai_plan_assigned_at
    assert_equal BigDecimal("1200"), AiMonthLimit.find_by!(workspace: workspace, month: Date.current.beginning_of_month).limit_usd
    assert_equal "Plan assigned", flash[:clar_toast]
  end

  test "an organization's page splits cost and price by area and project" do
    workspaces(:one).update!(ai_plan: ai_plans(:scale))
    billed_run!(cost: 100)
    billed_run!(cost: 50, margin: 25, area: "task_conversations", project: projects(:plain_project))

    get hidmin_workspace_path(workspaces(:one))
    billing = css_select("[data-billing]").text.squish
    assert_includes billing, "$150.00"
    assert_includes billing, "$192.50"
    assert_includes billing, "$42.50"
    assert_includes billing, "PR reviews $100.00 $130.00"
    assert_includes billing, "Internal $50.00 $62.50"
    assert_includes billing, "25%"
  end

  test "own-key usage is billed to them and outside the total" do
    billed_run!(cost: 10)
    billed_run!(cost: 24.60, own_key: true, area: "designs", project: projects(:other_jira_project))

    get hidmin_workspace_path(workspaces(:one))
    own = css_select("[data-billing] [data-own-key-row]").text.squish
    assert_includes own, "SecretProject"
    assert_includes own, "billed to them"
    assert_includes own, "$24.60"
    assert_includes css_select("[data-billing-total]").text.squish, "$10.00"
  end

  test "existing organization settings are still on the page" do
    get hidmin_workspace_path(workspaces(:one))
    assert_select "h2", text: "People"
    assert_select "h2", text: "Settings"
  end


  test "an area whose runs all reported no cost reads unknown on the organization's page" do
    billed_run!(cost: 10)
    billed_run!(cost: nil, area: "ticket_chat")
    get hidmin_workspace_path(workspaces(:one))
    row = css_select("[data-billing-row]").map { |r| r.text.squish }.find { |t| t.start_with?("Chat with AI on a ticket") }
    assert_equal "Chat with AI on a ticket unknown unknown", row
  end

end
