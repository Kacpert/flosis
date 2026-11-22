require "test_helper"

# Feedback on an import's page (Kacper, 2026-11-22): what the person does
# with what the import needed from them. Each action queues more work on the
# same import, or sets the suggestion aside.
class Workshop::DesignImportSuggestionsControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    workspaces(:one).update!(workshop_enabled: true)
    @project = projects(:jira_project)
    @project.update!(designs_enabled: true, design_repo_status: "ready")
    sign_in_as(users(:one))
    post switch_product_path, params: { product: "workshop" }
    post switch_workshop_project_path, params: { project_id: @project.id }
    @import = @project.design_setups.create!(status: "approved", phase: "feature", step: 6, started_by: users(:one),
                                             finished_at: 1.hour.ago, settled_at: 1.hour.ago)
    @import.features.create!(name: "Library", key: "library", position: 1, status: "done", contexts: %w[1-admin], brief: "The library.")
    @suggestion = DesignImportSuggestion.record!(@import, kind: "context", title: "Flosis staff sees the Library", context_name: "Flosis staff", features: %w[library])
  end

  def page_path = workshop_designs_overview_path(tab: "imports", import: @import.id)

  test "Build from code adds a code-only context and imports its screens" do
    post from_code_workshop_design_import_suggestion_path(@import, @suggestion)

    assert_redirected_to page_path
    assert_equal "Importing Flosis staff from the code", flash[:clar_toast]
    assert @project.design_setup_roles.find_by!(name: "Flosis staff").code_only?
    assert_equal [ "done", users(:one) ], [ @suggestion.reload.status, @suggestion.acted_by ]
    assert_equal "todo", @import.features.find_by!(key: "library").status
    assert_enqueued_with(job: Designs::SetupRunJob, args: [ @import.id ])
  end

  test "Add login adds the context with its login and imports its screens" do
    post add_login_workshop_design_import_suggestion_path(@import, @suggestion),
         params: { login_url: "https://staging.acme.test/login", login: "staff@staging.test", password: "s3cret" }

    assert_equal "Importing Flosis staff", flash[:clar_toast]
    role = @project.design_setup_roles.find_by!(name: "Flosis staff")
    assert_equal [ false, "staff@staging.test", "s3cret" ], [ role.code_only, role.username, role.password ]
    assert_equal "done", @suggestion.reload.status
  end

  test "Add login without a password shows the problem" do
    post add_login_workshop_design_import_suggestion_path(@import, @suggestion),
         params: { login_url: "https://staging.acme.test/login", login: "staff@staging.test", password: "" }

    assert_equal "Fill in the login URL, the login and the password.", flash[:clar_toast]
    refute @project.design_setup_roles.exists?(name: "Flosis staff")
    assert_equal "open", @suggestion.reload.status
  end

  test "Fix login saves the new login and imports that context again" do
    role = @project.design_setup_roles.create!(name: "PO", login_url: "https://s.test/login", username: "po", password: "old", position: 1)
    @import.features.find_by!(key: "library").update!(from_code: [ Designs::SignIn.slug(role) ])
    failed = DesignImportSuggestion.record!(@import, kind: "sign_in", title: "PO could not sign in", detail: "Wrong password.", role: role)

    post fix_login_workshop_design_import_suggestion_path(@import, failed), params: { login_url: "https://s.test/login", login: "po", password: "new" }
    assert_equal "new", role.reload.password
    assert_equal "done", failed.reload.status
    assert_equal "todo", @import.features.find_by!(key: "library").status
  end

  test "Dismiss sets it aside" do
    post dismiss_workshop_design_import_suggestion_path(@import, @suggestion)

    assert_equal "dismissed", @suggestion.reload.status
    assert_no_enqueued_jobs only: Designs::SetupRunJob
  end

  test "only people with the configuration permission act on suggestions" do
    project_memberships(:two_elvium).update!(designs: true, configuration: false)
    sign_in_as(users(:two))
    post switch_product_path, params: { product: "workshop" }
    post switch_workshop_project_path, params: { project_id: @project.id }

    post dismiss_workshop_design_import_suggestion_path(@import, @suggestion)
    assert_equal "open", @suggestion.reload.status
  end
end
