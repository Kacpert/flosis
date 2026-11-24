require "test_helper"

# The Designs setup form's saving (Workshop Designs v2), shared by the setup
# and by New import (Kacper, 2026-11-22: "New import nie powinien od razu
# odpalać importu tylko dać formularz").
class Designs::SetupFormTest < ActiveSupport::TestCase
  FORM = {
    ui: "tailwind", ui_version: "4", repo: "github.com/acme/app-designs", repo_token: "ghp_designs_token",
    repos: { "0" => { role: "Frontend", url: "github.com/acme/app@production" } },
    contexts: { "0" => { name: "Admin", url: "https://staging.acme.test/login", login: "admin@staging.test", password: "secret-pass" } }
  }.freeze

  setup { @project = projects(:jira_project) }

  def form(params) = Designs::SetupForm.new(@project, ActionController::Parameters.new(params).permit!)

  test "saves the stack, the repositories and the contexts" do
    assert form(FORM).save
    @project.reload
    assert_equal [ "tailwind", "4", "acme/app-designs", "https://staging.acme.test" ],
                 [ @project.designs_ui_system, @project.designs_ui_version, @project.design_repo, @project.design_app_url ]
    assert_equal [ { "role" => "Frontend", "repo" => "acme/app@production" } ], @project.design_app_repos
    assert_equal [ "Admin", "admin@staging.test", "secret-pass" ], @project.design_setup_roles.sole.then { [ _1.name, _1.username, _1.password ] }
  end

  test "refuses a form without a designs repository, an app repository or a context" do
    [ FORM.merge(repo: ""), FORM.merge(repos: {}), FORM.merge(contexts: {}) ].each do |params|
      saving = form(params)
      refute saving.save
      assert_equal Designs::SetupForm::INCOMPLETE, saving.error
    end
  end

  test "a saved password stays when left blank, and a new context needs one" do
    assert form(FORM).save
    role = @project.design_setup_roles.sole
    assert form(FORM.merge(contexts: { "0" => { id: role.id.to_s, name: "Admin", url: "https://staging.acme.test/login", login: "admin@staging.test", password: "" } })).save
    assert_equal "secret-pass", role.reload.password

    refute form(FORM.merge(contexts: { "0" => { name: "Manager", url: "https://staging.acme.test/login", login: "m@staging.test", password: "" } })).save
  end

  test "what the record refuses is the error" do
    saving = form(FORM.merge(repo: "github.com/acme/app.git"))
    refute saving.save
    assert_includes saving.error, "Design repo must be a different repository from the app's"
  end

  # Kacper, 2026-11-22: a context with no login is built from the code.
  test "a context with No login is saved code-only, without URL, login or password" do
    params = FORM.merge(contexts: FORM[:contexts].merge("1" => { name: "Flosis staff", url: "", login: "", password: "", code_only: "1" }))
    assert form(params).save
    staff = @project.design_setup_roles.find_by!(name: "Flosis staff")
    assert staff.code_only?
    assert_equal [ nil, nil ], [ staff.login_url.presence, staff.username.presence ]
    assert_equal "https://staging.acme.test", @project.reload.design_app_url
  end

  # Final review I7 (2026-11-22): a context's slug ("3-flosis-staff") is its
  # position and name, and the map's features name contexts by it.
  test "removing a context keeps the others' slugs" do
    contexts = { "0" => { name: "Admin", url: "https://s.test/login", login: "a", password: "p" },
                 "1" => { name: "Guest", url: "https://s.test/login", login: "g", password: "p" },
                 "2" => { name: "Flosis staff", code_only: "1" } }
    assert form(FORM.merge(contexts: contexts)).save
    staff = @project.design_setup_roles.find_by!(name: "Flosis staff")
    assert_equal "3-flosis-staff", Designs::SignIn.slug(staff)

    admin = @project.design_setup_roles.find_by!(name: "Admin")
    kept = { "0" => { id: admin.id.to_s, name: "Admin", url: "https://s.test/login", login: "a", password: "" },
             "1" => { id: staff.id.to_s, name: "Flosis staff", code_only: "1" },
             "2" => { name: "Manager", url: "https://s.test/login", login: "m", password: "p" } }
    assert form(FORM.merge(contexts: kept)).save
    assert_equal "3-flosis-staff", Designs::SignIn.slug(staff.reload)
    assert_equal "4-manager", Designs::SignIn.slug(@project.design_setup_roles.find_by!(name: "Manager"))
  end
end
