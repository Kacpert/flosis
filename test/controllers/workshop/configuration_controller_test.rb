require "test_helper"

class Workshop::ConfigurationControllerTest < ActionDispatch::IntegrationTest
  setup do
    @workspace = workspaces(:one)
    @workspace.update!(workshop_enabled: true)
    @project = projects(:jira_project)
    sign_in_as(users(:one)) # admin/owner
    post switch_product_path, params: { product: "workshop" }
    post switch_workshop_project_path, params: { project_id: @project.id }
  end

  test "admin GET show renders the Configuration shell and AI tab by default" do
    get workshop_configuration_path

    assert_response :success
    assert_select "h1", "Configuration"
    assert_select "body", /Per-project credentials, AI behaviour and access\./
    assert_select ".clar-tab", /Integrations/
    assert_select ".clar-tab", /AI/
    assert_select ".clar-tab", /Users/ # admin sees the Users tab

    # AI tab content (default tab)
    assert_select "body", /Claude Opus/
    assert_select "body", /active/
    assert_select "body", /Configurable dependency\. Only Claude Opus is in scope today\./
    assert_select "textarea"
    assert_select "input[type=range]"
    assert_select "body", /effective minimum 7/
    assert_select "body", /Estimation target/
  end

  test "admin GET show with tab=integrations renders the integrations tab (Task 9.2: 4 cards, no longer a placeholder)" do
    get workshop_configuration_path(tab: "integrations")

    assert_response :success
    assert_select ".clar-tab-active", /Integrations/
    assert_select "body", /GitHub/
    assert_select "body", /Jira Cloud/
    assert_select "body", /Discord/
    assert_select "body", /Figma/
  end

  # Access is per-project now, so "the member list" is this project's
  # ProjectMemberships, and the badge is derived from their switches rather
  # than a workspace-wide role — see PermissionPreset.
  test "admin GET show with tab=users lists this project's members with permission-derived badges" do
    project_memberships(:one_elvium).update!(PermissionPreset.attributes_for("Administrator"))
    project_memberships(:two_elvium).update!(PermissionPreset.attributes_for("Product Owner"))

    get workshop_configuration_path(tab: "users")

    assert_response :success
    assert_select ".clar-tab-active", /Users/

    assert_select "body", /Kacper/
    assert_select "body", /one@example\.com/
    assert_select "body", /Other User/
    assert_select "body", /two@example\.com/
    # Client Person is still a member of this project (client_elvium fixture)
    # and still shows, with whatever the switches on their row say.
    assert_select "body", /Client Person/

    assert_select ".clar-badge-warn", /Administrator/
    assert_select ".clar-badge-primary", /Product Owner/
  end

  # The locked reading wins over the row's own columns: an administrator holds
  # all six by the workspace flag, so the grid must not read their switches
  # back and call them a Project Manager.
  test "an administrator's row reads as Administrator whatever its switches say" do
    admin_row = project_memberships(:one_elvium)
    admin_row.update!(PermissionPreset.attributes_for("Project Manager"))

    get workshop_configuration_path(tab: "users")

    assert_response :success
    assert_select "#project_membership_#{admin_row.id}" do
      assert_select ".clar-badge-warn", /Administrator/
      assert_select "[role=switch][aria-checked=true]", 6
    end
  end

  test "users tab shows a muted Custom badge for a permission set matching no preset" do
    project_memberships(:two_elvium).update!(pricing: true) # off every preset

    get workshop_configuration_path(tab: "users")

    assert_response :success
    assert_select ".clar-badge-muted", /Custom/
  end

  # Eight of the fifteen people on production hold an all-off row: it is there
  # so their hours and their hourly rate attach to a project, and "Custom" told
  # their managers somebody had chosen that combination for them.
  test "users tab reads a row granting nothing as No access, and the legend says what such a row means" do
    row = project_memberships(:client_elvium)
    row.update!(PermissionPreset::PERMISSIONS.index_with(false))

    get workshop_configuration_path(tab: "users")

    assert_response :success
    assert_select "#project_membership_#{row.id}" do
      assert_select ".clar-badge-muted", PermissionPreset::NONE
    end
    # Scoped to the legend: the grid prints this label too, so the body alone
    # cannot say whether the explanation reached the page.
    assert_select "[data-permission-legend]" do
      assert_select "dt", text: PermissionPreset::NONE
      assert_select "dd", /hours and hourly rate attach to this project/
    end
  end

  # Inviting is per project now, so the header opens the Workshop's own dialog
  # instead of sending the admin to HR's workspace-wide invite screen.
  test "users tab invites from the Workshop, not from HR" do
    get workshop_configuration_path(tab: "users")

    assert_response :success
    assert_select "button[data-clar-modal-id-param=?]", "invite", /Invite/
    assert_select "a[href=?]", new_workspace_member_path, false
  end

  # The grid is six unlabelled toggles unless the screen says what they mean.
  # PermissionPreset::LABELS/DESCRIPTIONS is the only copy there is, so this
  # pins that it actually reaches the page.
  test "users tab names and explains every permission" do
    get workshop_configuration_path(tab: "users")

    assert_response :success
    PermissionPreset::PERMISSIONS.each do |permission|
      assert_select "body", /#{Regexp.escape(PermissionPreset.description(permission))}/
    end
    assert_select "body", /Briefing Configuration/
    # Not `humanize`, which reads "Briefing config" — see PermissionPreset::LABELS.
    assert_no_match(/Briefing config\b/, response.body)
  end

  # Both dialogs sit in the Users card's single clar-modal scope and are told
  # apart only by their panel id, so a wrong id is a button that opens the
  # other dialog. Each one is also where someone decides what a new person
  # will be able to see, which is why all six sentences have to be in both.
  test "users tab renders both dialogs, each explaining all six permissions" do
    get workshop_configuration_path(tab: "users")

    assert_response :success

    assert_select "[data-clar-modal-panel-id-value=?]", "invite" do
      assert_select "input[name=?]", "email_address"
      PermissionPreset::PRESETS.each_key do |preset|
        assert_select "[data-preset-picker-name-param=?]", preset
      end
      PermissionPreset::PERMISSIONS.each do |permission|
        assert_select "[aria-label=?]",
                      "#{PermissionPreset.label(permission)}: #{PermissionPreset.description(permission)}"
      end
    end

    assert_select "[data-clar-modal-panel-id-value=?]", "add-existing" do
      assert_select "input[name=?]", "email_address", false,
                    "adding someone who already has an account must not ask for an address"
      assert_select "[data-permission]", 6
    end
  end

  # Stimulus only claims a target whose closest clar-modal element IS the
  # controller's own, so a panel rendered one line past the closing </div> is
  # markup that exists and a button that does nothing. "The panel is on the
  # page" cannot tell the two apart; "the panel is inside the scope" can.
  test "both dialogs sit inside the clar-modal element, or no trigger can open them" do
    get workshop_configuration_path(tab: "users")

    assert_response :success
    # Named rather than counted: the top bar's own New project dialog is a
    # third panel on this page, inside the project switcher's clar-modal scope.
    assert_select '[data-controller~="clar-modal"] ' \
                  '[data-clar-modal-target="panel"][data-clar-modal-panel-id-value="invite"]', 1
    assert_select '[data-controller~="clar-modal"] ' \
                  '[data-clar-modal-target="panel"][data-clar-modal-panel-id-value="add-existing"]', 1
  end

  test "the add-from-another-project dialog offers a chip per person on another project" do
    project_memberships(:client_elvium).destroy!
    projects(:plain_project).project_memberships.create!(user: users(:client_user), hourly_rate_cents: 0)

    get workshop_configuration_path(tab: "users")

    assert_response :success
    assert_select "[data-clar-modal-panel-id-value=?]", "add-existing" do
      assert_select "input[name=?][value=?]", "user_ids[]", users(:client_user).id.to_s
    end
  end

  # The HR and Workshop directories are separate on purpose: an employee with
  # an account and no project was kept out of the Workshop, and one project's
  # Configuration holder must not be able to put them in it — nor be shown the
  # whole staff directory on the way.
  test "the add dialog does not offer an employee who is on no project" do
    hr_only = User.create!(name: "Nora Payroll", email_address: "nora@acme.io",
                           password: "password", password_confirmation: "password")
    @workspace.workspace_memberships.create!(user: hr_only, time_hr_access: true, workspace_admin: false)

    get workshop_configuration_path(tab: "users")

    assert_response :success
    assert_select "input[name=?][value=?]", "user_ids[]", hr_only.id.to_s, false,
                  "someone with no project at all is not 'on another project'"
    assert_no_match(/Nora Payroll/, response.body,
                    "the dialog must not disclose the staff directory")
  end

  test "someone holding Briefing but not Configuration is blocked from the users tab" do
    project_memberships(:two_elvium).update!(PermissionPreset.attributes_for("Product Owner"))
    sign_out
    sign_in_as(users(:two))
    post switch_product_path, params: { product: "workshop" }

    get workshop_configuration_path(tab: "users")
    # Bounced to the tab they DO hold, not thrown out of the page — they still
    # pass require_configuration_access! on Briefing alone.
    assert_redirected_to workshop_configuration_path(tab: "briefing")
  end

  test "someone holding neither Configuration nor Briefing is blocked from the whole page, and PATCH cannot persist" do
    project_memberships(:two_elvium).update!(PermissionPreset::PERMISSIONS.index_with(false))
    sign_out
    sign_in_as(users(:two))
    post switch_product_path, params: { product: "workshop" }

    # Their one row now grants nothing, which is no Workshop access at all, so
    # the refusal comes from require_product! and lands on Time & HR — the
    # product they do hold. It used to be workshop_landing_path's profile page,
    # reached through a Workshop they could not use a single page of.
    get workshop_configuration_path
    assert_redirected_to time_entries_path

    before = @project.reload.pr_poll_minutes
    patch workshop_configuration_path, params: { project: { pr_poll_minutes: 25 }, tab: "ai" }
    assert_redirected_to time_entries_path
    assert_equal before, @project.reload.pr_poll_minutes, "must not persist"
  end

  test "someone holding Briefing manages that tab, but Integrations/Users render locked and refuse server-side too" do
    project_memberships(:two_elvium).update!(PermissionPreset.attributes_for("Product Owner"))
    sign_out
    sign_in_as(users(:two))
    post switch_product_path, params: { product: "workshop" }

    get workshop_configuration_path
    assert_response :success
    assert_select ".clar-tab.clar-tab-active", /Briefing/
    # Users (and Integrations/AI) are SHOWN but locked — visible with a reason
    # beats silently missing. It must not be a link.
    assert_select "a.clar-tab", text: /Users/, count: 0
    assert_select "span.clar-tab[aria-disabled='true']", text: /Users/ do |tab|
      # data-tip drives the .clar-tip bubble; the native title attribute waited
      # ~1-2s before appearing, which read as nothing happening.
      assert_match(/Needs the Configuration permission/, tab.first["data-tip"], "locked tab must say why")
      assert_match(/needs the Configuration permission/, tab.first["aria-label"], "and say it to screen readers")
    end

    # Can manage the tab they hold.
    patch workshop_configuration_path, params: { tab: "briefing", project: { briefing_personas: "Recruiters." } }
    assert_equal "Recruiters.", @project.reload.briefing_personas

    # But cannot even reach the users tab — bounced to the tab they hold.
    get workshop_configuration_path(tab: "users")
    assert_redirected_to workshop_configuration_path(tab: "briefing")

    # Nor PATCH it — forbidden server-side, not silently accepted.
    patch workshop_configuration_path, params: { tab: "users" }
    assert_response :forbidden
  end

  # A padlock with no reason beside it sends the person to ask an administrator
  # a question the screen could have answered.
  test "a locked tab names the permission it needs" do
    workspace_memberships(:one_owner).update!(workspace_admin: false)
    project_memberships(:one_elvium).update!(PermissionPreset.attributes_for("Product Owner"))
    sign_in_as(users(:one))

    get workshop_configuration_path(tab: "briefing")

    assert_response :success
    assert_match "Needs the Configuration permission", response.body
  end

  # The padlock reads the permission through the same accessor the gate uses, so
  # a tab added to the view's list alone still names a real permission instead
  # of nil — which PermissionPreset.label would have turned into a 500 on the
  # whole page, where tab_permitted? merely refuses the tab.
  test "a tab nobody priced costs the Configuration permission, not nothing" do
    assert_equal :configuration, Workshop::ConfigurationController.new.send(:tab_permission, "audit_log")
  end

  # test_github and verify_jira_fields are Integrations-tab writes but used to
  # be gated only by the page (:configuration OR :briefing_config), not by the
  # tab. A Product Owner (briefing_config only, sees Integrations locked)
  # could still POST to either and mutate GitHub health / cached Jira field
  # ids. Both now require :configuration directly.
  test "a Product Owner cannot reach the Integrations endpoints they see locked" do
    # briefing_config on, configuration off
    project_memberships(:two_elvium).update!(PermissionPreset.attributes_for("Product Owner"))
    sign_out
    sign_in_as(users(:two))
    post switch_product_path, params: { product: "workshop" }

    post workshop_test_github_configuration_path
    assert_response :redirect

    post workshop_verify_jira_fields_configuration_path
    assert_response :redirect
  end

  test "PATCH update persists AI settings and toasts" do
    patch workshop_configuration_path, params: {
      project: {
        pr_review_prompt: "Custom prompt text for reviews.",
        pr_poll_minutes: 15,
        estimation_trigger: "status",
        estimation_field_names: [ "Story point estimate", "Confidence (1–5)" ],
        estimation_status_trigger: "Ready for dev",
        figma_read_enabled: true
      },
      tab: "ai"
    }

    assert_redirected_to workshop_configuration_path(tab: "ai")
    @project.reload
    assert_equal "Custom prompt text for reviews.", @project.pr_review_prompt
    assert_equal 15, @project.pr_poll_minutes
    assert_equal "status", @project.estimation_trigger
    assert_equal [ "Story point estimate", "Confidence (1–5)" ], @project.estimation_field_names
    assert_equal true, @project.figma_read_enabled
    assert_match(/AI settings saved/, flash[:clar_toast])
  end

  test "PATCH update saves briefing_personas onto the current workshop project" do
    patch workshop_configuration_path, params: {
      project: { briefing_personas: "  Recruiters posting jobs; Admins configuring.  " },
      tab: "briefing"
    }

    assert_redirected_to workshop_configuration_path(tab: "briefing")
    assert_equal "Recruiters posting jobs; Admins configuring.", @project.reload.briefing_personas
    assert_match(/Briefing settings saved/, flash[:clar_toast])
  end

  # The personas were wiped by a request that never mentioned them, and the
  # toast said it had saved.
  test "PATCH update to the briefing tab with no project key refuses and keeps the personas" do
    @project.update!(briefing_personas: "Recruiters and admins.")

    patch workshop_configuration_path, params: { tab: "briefing" }

    assert_response :bad_request
    assert_equal "Recruiters and admins.", @project.reload.briefing_personas
    refute_match(/Briefing settings saved/, flash[:clar_toast].to_s)
  end

  test "PATCH update to the briefing tab reports a failed save instead of toasting success" do
    original = Project.instance_method(:update)
    Project.define_method(:update) do |*_args|
      errors.add(:base, "Briefing personas could not be stored")
      false
    end

    begin
      patch workshop_configuration_path, params: {
        project: { briefing_personas: "Recruiters." }, tab: "briefing"
      }
    ensure
      Project.define_method(:update, original)
    end

    assert_match(/could not be stored/, flash[:alert])
    refute_match(/Briefing settings saved/, flash[:clar_toast].to_s)
  end

  test "the Briefing tab shows the personas field, the feature-summary card, and a Refresh button" do
    @project.update!(briefing_personas: "Recruiters and admins.",
                     features_summary: "Users can post jobs and review candidates.",
                     features_summary_updated_at: 2.hours.ago)

    get workshop_configuration_path(tab: "briefing")

    assert_response :success
    assert_select ".clar-tab.clar-tab-active", /Briefing/
    assert_select "textarea[name='project[briefing_personas]']", /Recruiters and admins\./
    assert_select "body", /what the app already does/i
    assert_select "body", /Users can post jobs and review candidates\./
    assert_select "form[action='#{workshop_refresh_features_configuration_path}']"
  end

  test "the AI tab no longer carries the briefing personas field" do
    get workshop_configuration_path(tab: "ai")

    assert_response :success
    assert_select "textarea[name='project[briefing_personas]']", false
  end

  test "refresh_features enqueues a single-project scan and toasts" do
    assert_enqueued_with(job: ProjectFeaturesScanJob, args: [ @project.id ]) do
      post workshop_refresh_features_configuration_path
    end

    assert_redirected_to workshop_configuration_path(tab: "briefing")
    assert_match(/Refreshing the app feature summary/, flash[:clar_toast])
  end

  test "PATCH update rejects a blank estimation_field_names array" do
    @project.update!(estimation_field_names: [ "Story point estimate" ])

    patch workshop_configuration_path, params: {
      project: { estimation_field_names: [ "" ] },
      tab: "ai"
    }

    assert_equal [ "Story point estimate" ], @project.reload.estimation_field_names
  end

  # ---- Integrations tab (Task 9.2) ----------------------------------------

  test "integrations tab renders the 4 cards with live status/detail" do
    @project.update!(
      github_repo: "acme/survey-platform", github_token: "ghp_abcd1234a3f1",
      github_status_ok: true, github_status_checked_at: 2.hours.ago,
      pr_review_enabled: true, figma_read_enabled: true
    )
    DiscordWebhook.create!(workspace: @workspace, project: @project, channel_name: "#dev-alerts", url: "https://discord.com/api/webhooks/1/a")
    DiscordWebhook.create!(workspace: @workspace, project: @project, channel_name: "#product", url: "https://discord.com/api/webhooks/2/b")
    # Another project's webhook must not be counted on this project's card.
    DiscordWebhook.create!(workspace: @workspace, project: projects(:plain_project),
      channel_name: "#internal", url: "https://discord.com/api/webhooks/3/c")
    ENV["JIRA_DOMAIN"] = "acme.atlassian.net"
    ENV["JIRA_EMAIL"] = "a@example.com"
    ENV["JIRA_API_TOKEN"] = "tok"

    get workshop_configuration_path(tab: "integrations")

    assert_response :success
    assert_select "body", /GitHub/
    assert_select "body", /acme\/survey-platform/
    assert_select "body", /a3f1/
    assert_select "body", /Jira Cloud/
    assert_select "body", /Connected/
    assert_select "body", /Discord/
    assert_select "body", /2 webhooks/
    assert_select "body", /Figma/
  end

  test "someone without Configuration or Briefing is blocked from the integrations endpoints too" do
    project_memberships(:two_elvium).update!(PermissionPreset::PERMISSIONS.index_with(false))
    sign_out
    sign_in_as(users(:two))
    post switch_product_path, params: { product: "workshop" }

    # Time & HR, not the profile page: a row granting nothing is no Workshop
    # access, so require_product! refuses before any permission is asked for.
    get workshop_configuration_path(tab: "integrations")
    assert_redirected_to time_entries_path

    post workshop_test_github_configuration_path
    assert_redirected_to time_entries_path

    post workshop_verify_jira_fields_configuration_path
    assert_redirected_to time_entries_path
  end

  test "POST test_github runs the health check, persists status on the project, and toasts" do
    @project.update!(github_token: "t", github_repo: "acme/widgets")
    fake = Object.new
    fake.define_singleton_method(:health_check) { { ok: true } }
    orig = GithubClient.method(:for_project)
    GithubClient.define_singleton_method(:for_project) { |*_a, **_k| fake }

    post workshop_test_github_configuration_path

    assert_redirected_to workshop_configuration_path(tab: "integrations")
    assert @project.reload.github_status_ok
    assert_match(/GitHub connection OK/, flash[:clar_toast])
  ensure
    GithubClient.define_singleton_method(:for_project, orig)
  end

  test "POST test_github stores the error when the health check fails" do
    @project.update!(github_token: "t", github_repo: "acme/widgets")
    fake = Object.new
    fake.define_singleton_method(:health_check) { { ok: false, error: "401 Unauthorized" } }
    orig = GithubClient.method(:for_project)
    GithubClient.define_singleton_method(:for_project) { |*_a, **_k| fake }

    post workshop_test_github_configuration_path

    @project.reload
    assert_not @project.github_status_ok
    assert_equal "401 Unauthorized", @project.github_status_error
    assert_match(/GitHub connection failed/, flash[:clar_toast])
  ensure
    GithubClient.define_singleton_method(:for_project, orig)
  end

  test "POST verify_jira_fields resolves and caches the 3 field ids and toasts" do
    ENV["JIRA_DOMAIN"] = "acme.atlassian.net"
    ENV["JIRA_EMAIL"] = "a@example.com"
    ENV["JIRA_API_TOKEN"] = "tok"
    @project.update!(jira_ai_actions_field_id: nil, jira_ai_estimation_field_id: nil, jira_story_points_field_id: nil)

    fake = Object.new
    fake.define_singleton_method(:fetch_field_id) do |name|
      { "AI actions" => "customfield_1", "AI estimation" => "customfield_2", "Story point estimate" => "customfield_3" }[name]
    end
    orig = JiraClient.method(:new)
    JiraClient.define_singleton_method(:new) { |*_a, **_k| fake }

    post workshop_verify_jira_fields_configuration_path

    assert_redirected_to workshop_configuration_path(tab: "integrations")
    @project.reload
    assert_equal "customfield_1", @project.jira_ai_actions_field_id
    assert_equal "customfield_2", @project.jira_ai_estimation_field_id
    assert_equal "customfield_3", @project.jira_story_points_field_id
    assert_match(/fields verified/i, flash[:clar_toast])
  ensure
    JiraClient.define_singleton_method(:new, orig)
  end

  test "PATCH update persists GitHub modal fields and a blank token keeps the existing one" do
    @project.update!(github_repo: "acme/old", github_token: "existing-token", pr_review_enabled: false)

    patch workshop_configuration_path, params: {
      tab: "integrations", integration: "github",
      project: { github_repo: "acme/new-repo", github_token: "", pr_review_enabled: true }
    }

    @project.reload
    assert_equal "acme/new-repo", @project.github_repo
    assert_equal "existing-token", @project.github_token, "blank token must not wipe the existing one"
    assert_equal true, @project.pr_review_enabled
  end

  test "PATCH update persists a non-blank GitHub token (rotate)" do
    @project.update!(github_token: "old-token")

    patch workshop_configuration_path, params: {
      tab: "integrations", integration: "github", project: { github_token: "brand-new-token" }
    }

    assert_equal "brand-new-token", @project.reload.github_token
  end

  test "saving the GitHub integration queues a checkout of the project's repo" do
    assert_enqueued_with(job: ProjectRepoCheckoutJob, args: [ @project.id ]) do
      patch workshop_configuration_path, params: {
        tab: "integrations", integration: "github",
        project: { github_repo: "acme/app", github_token: "ght" }
      }
    end
  end

  test "saving GitHub without a token queues no checkout" do
    @project.update!(github_token: nil)
    assert_no_enqueued_jobs(only: ProjectRepoCheckoutJob) do
      patch workshop_configuration_path, params: {
        tab: "integrations", integration: "github", project: { github_repo: "acme/app", github_token: "" }
      }
    end
  end

  test "saving another integration queues no checkout, even with GitHub already configured" do
    @project.update!(github_repo: "acme/app", github_token: "ght")
    assert_no_enqueued_jobs(only: ProjectRepoCheckoutJob) do
      patch workshop_configuration_path, params: {
        tab: "integrations", integration: "figma", project: { figma_read_enabled: true, figma_token: "" }
      }
    end
  end

  test "PATCH update persists the Figma token and toggle, and a blank token keeps the stored one" do
    @project.update!(figma_read_enabled: false, figma_token: "figd_keep-me")

    patch workshop_configuration_path, params: {
      tab: "integrations", integration: "figma",
      project: { figma_read_enabled: true, figma_token: "" }
    }

    @project.reload
    assert_equal true, @project.figma_read_enabled
    assert_equal "figd_keep-me", @project.figma_token, "blank token must not wipe the existing one"
  end

  test "the AI tab saves onto the project, not the workspace" do
    patch workshop_configuration_path, params: {
      tab: "ai", project: { pr_poll_minutes: 21, pr_review_prompt: "Be brief." }
    }

    assert_equal 21, @project.reload.pr_poll_minutes
    assert_equal "Be brief.", @project.pr_review_prompt
  end

  test "a blank secret preserves the one already stored" do
    @project.update!(github_token: "keep-me")

    patch workshop_configuration_path, params: {
      tab: "integrations", integration: "github", project: { github_repo: "acme/new", github_token: "" }
    }

    assert_equal "keep-me", @project.reload.github_token
    assert_equal "acme/new", @project.github_repo
  end

  test "the AI tab takes the project's own Anthropic key, and a blank field keeps it" do
    get workshop_configuration_path(tab: "ai")
    assert_select "input[type=password][name='project[anthropic_api_key]']"
    @project.update!(anthropic_api_key: "sk-ant-keep")
    patch workshop_configuration_path, params: { tab: "ai", project: { anthropic_api_key: "" } }
    assert_equal "sk-ant-keep", @project.reload.anthropic_api_key
  end

  test "the AI tab never shows the key, only its last four characters" do
    @project.update!(anthropic_api_key: "sk-ant-secret-wxyz")
    get workshop_configuration_path(tab: "ai")
    assert_select "input[name='project[anthropic_api_key]']:not([value])"
    assert_select "input[name='project[anthropic_api_key]'][placeholder$=?]", "wxyz"
    assert_no_match(/sk-ant-secret/, response.body)
    assert_select "body", /Designs runs only on this key\. Claude is billed to it, not to Flosis\./
  end

  test "the key's last characters are shown as text, never as markup" do
    @project.update!(anthropic_api_key: %(sk-ant-x"<i>))
    get workshop_configuration_path(tab: "ai")
    assert_select "input[name='project[anthropic_api_key]'][placeholder$=?]", %("<i>)
    assert_select ".clar-card i", count: 0
  end
end
