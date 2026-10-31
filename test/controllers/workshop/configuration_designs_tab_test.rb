require "test_helper"

class Workshop::ConfigurationDesignsTabTest < ActionDispatch::IntegrationTest
  setup do
    @workspace = workspaces(:one)
    @workspace.update!(workshop_enabled: true)
    @project = projects(:jira_project)
    sign_in_as(users(:one))
    post switch_product_path, params: { product: "workshop" }
    post switch_workshop_project_path, params: { project_id: @project.id }
  end

  test "the Designs tab shows the on/off switch, repository, token and kit" do
    get workshop_configuration_path(tab: "designs")
    assert_response :success
    assert_select ".clar-tab-active", /Designs/
    assert_select "input[name='project[designs_enabled]']"
    assert_select "input[name='project[design_repo]']"
    assert_select "input[type=password][name='project[design_repo_token]']"
    assert_select "select[name='project[design_base_kit]'] option[value=tailwind4]"
    assert_select "select[name='project[design_base_kit]'] option[value=plain]"
  end

  test "switching Designs on with a repo and a token saves them and starts setting the repo up" do
    assert_enqueued_with(job: Designs::InitializeRepoJob, args: [ @project.id ]) do
      patch workshop_configuration_path, params: { tab: "designs", project: {
        designs_enabled: "1", design_repo: "acme/designs", design_repo_token: "dt", design_base_kit: "tailwind4" } }
    end
    @project.reload
    assert @project.designs_enabled?
    assert_equal "acme/designs", @project.design_repo
    assert_equal "dt", @project.design_repo_token
    assert_equal "initializing", @project.design_repo_status
    assert_redirected_to workshop_configuration_path(tab: "designs")
  end

  test "a blank token keeps the stored one" do
    @project.update!(design_repo_token: "keep-me")
    patch workshop_configuration_path, params: { tab: "designs", project: { design_repo: "acme/designs", design_repo_token: "" } }
    assert_equal "keep-me", @project.reload.design_repo_token
  end

  test "Designs left off queues nothing" do
    assert_no_enqueued_jobs(only: Designs::InitializeRepoJob) do
      patch workshop_configuration_path, params: { tab: "designs", project: {
        designs_enabled: "0", design_repo: "acme/designs", design_repo_token: "dt" } }
    end
  end

  test "a ready repo links to the master preview" do
    @project.update!(designs_enabled: true, design_repo: "acme/designs", design_repo_token: "dt",
                     design_repo_status: "ready", design_preview_token: "t0k")
    get workshop_configuration_path(tab: "designs")
    assert_select "a[href=?][target=_blank]", "#{Designs::Publisher.base_url}/t0k/master/index.html"
  end

  test "a failed setup shows git's message" do
    @project.update!(design_repo_status: "error", design_repo_error: "git push failed: permission denied")
    get workshop_configuration_path(tab: "designs")
    assert_select "body", /permission denied/
  end

  test "rotating the preview links changes the token" do
    @project.update!(design_preview_token: "old-token-old-token-old-token-12")
    post workshop_rotate_design_preview_token_configuration_path
    assert_redirected_to workshop_configuration_path(tab: "designs")
    assert_not_equal "old-token-old-token-old-token-12", @project.reload.design_preview_token
  end

  test "a Product Owner sees the Designs tab locked and can neither save nor rotate" do
    @project.update!(design_preview_token: "old-token-old-token-old-token-12")
    project_memberships(:two_elvium).update!(PermissionPreset.attributes_for("Product Owner"))
    sign_out
    sign_in_as(users(:two))
    post switch_product_path, params: { product: "workshop" }

    get workshop_configuration_path
    assert_select "span.clar-tab[aria-disabled='true']", text: /Designs/

    patch workshop_configuration_path, params: { tab: "designs", project: { designs_enabled: "1" } }
    assert_response :forbidden
    post workshop_rotate_design_preview_token_configuration_path
    @project.reload
    assert_not @project.designs_enabled?
    assert_equal "old-token-old-token-old-token-12", @project.design_preview_token
  end

  # ---- Beyond the brief: the rulings, and what the brief's tests leave open ----

  test "the Designs tab sits between Briefing and Users" do
    get workshop_configuration_path(tab: "designs")
    assert_equal %w[Integrations AI Briefing Designs Users],
                 css_select(".clar-tabs > .clar-tab").map { |tab| tab.text.strip }
  end

  test "a Product Owner asking for the Designs tab is sent to the one they hold" do
    project_memberships(:two_elvium).update!(PermissionPreset.attributes_for("Product Owner"))
    sign_out
    sign_in_as(users(:two))
    post switch_product_path, params: { product: "workshop" }

    get workshop_configuration_path(tab: "designs")
    assert_redirected_to workshop_configuration_path(tab: "briefing")
  end

  test "a pasted GitHub URL is forgiven and saved as owner/name" do
    patch workshop_configuration_path, params: { tab: "designs", project: {
      design_repo: "https://github.com/acme/designs.git" } }
    assert_equal "acme/designs", @project.reload.design_repo
  end

  test "the switch shows what is stored" do
    get workshop_configuration_path(tab: "designs")
    assert_select "button.clar-toggle[aria-checked=false]"

    @project.update!(designs_enabled: true)
    get workshop_configuration_path(tab: "designs")
    assert_select "button.clar-toggle[aria-checked=true]"
  end

  test "the kit select shows the stored kit and names both kits" do
    @project.update!(design_base_kit: "plain")
    get workshop_configuration_path(tab: "designs")
    assert_select "select[name='project[design_base_kit]'] option[selected][value=plain]", text: "Plain CSS"
    assert_select "select[name='project[design_base_kit]'] option[value=tailwind4]", text: "Tailwind v4"
  end

  test "the kit is saved, and a kit Flosis does not have is refused" do
    patch workshop_configuration_path, params: { tab: "designs", project: { design_base_kit: "plain" } }
    assert_equal "plain", @project.reload.design_base_kit
    assert_match(/Designs settings saved/, flash[:clar_toast])

    patch workshop_configuration_path, params: { tab: "designs", project: { design_base_kit: "bootstrap5" } }
    assert_equal "plain", @project.reload.design_base_kit
    assert_match(/Design base kit/, flash[:alert])
  end

  test "the page keeps the stored token out of the markup, and says only whether one is set" do
    get workshop_configuration_path(tab: "designs")
    assert_select "input[name='project[design_repo_token]'][placeholder=?]", "Not set"

    token = "github_pat_0123456789abcdefghijklmnopqrstuvwxyz"
    @project.update!(design_repo: "acme/designs", design_repo_token: token)
    get workshop_configuration_path(tab: "designs")
    assert_select "input[type=password][name='project[design_repo_token]']:not([value])"
    assert_select "input[name='project[design_repo_token]'][placeholder=?]", "Not set", false
    assert_not_includes response.body, token
    assert_not_includes response.body, token.last(12), "only the last four characters may show"
  end

  test "the status card says where the repository stands" do
    get workshop_configuration_path(tab: "designs")
    assert_select "[data-design-status]", /Not set up/
    assert_select "a", text: /Open master preview/, count: 0

    @project.update!(design_repo_status: "initializing")
    get workshop_configuration_path(tab: "designs")
    assert_select "[data-design-status]", /Setting up/
    assert_select "[data-design-status]", /If this takes more than a few minutes, save again to retry\./
    assert_select "a", text: /Open master preview/, count: 0

    @project.update!(design_repo_status: "error", design_repo_error: "git push failed: permission denied")
    get workshop_configuration_path(tab: "designs")
    assert_select "[data-design-status]", /Failed: git push failed: permission denied/
    assert_select "a", text: /Open master preview/, count: 0

    @project.update!(designs_enabled: true, design_repo_status: "ready", design_preview_token: "t0k")
    get workshop_configuration_path(tab: "designs")
    assert_select "[data-design-status]", /Ready/
    assert_select "a", text: /Open master preview/
  end

  # Off, nothing runs and nothing is offered: a repo set up before is not
  # "Ready", and the tab links to none of its previews.
  test "with Designs off a set-up repo is not shown as Ready, and its master preview is not linked" do
    @project.update!(designs_enabled: false, design_repo_status: "ready", design_preview_token: "t0k")
    get workshop_configuration_path(tab: "designs")
    assert_select "[data-design-status=off]", /Designs is off/
    assert_select "[data-design-status]", text: /Ready/, count: 0
    assert_select "a", text: /Open master preview/, count: 0
    assert_not_includes response.body, "/t0k/master/"
  end

  test "the master preview opens in a new tab without handing over the opener" do
    @project.update!(designs_enabled: true, design_repo_status: "ready", design_preview_token: "t0k")
    get workshop_configuration_path(tab: "designs")
    assert_select "a[href=?][target=_blank][rel='noopener noreferrer']",
                  "#{Designs::Publisher.base_url}/t0k/master/index.html", text: /Open master preview/
  end

  # A git failure quotes whatever the remote said, and the remote is the client's.
  test "git's message is shown as text, never as markup" do
    @project.update!(design_repo_status: "error", design_repo_error: "boom <script>alert(1)</script> <b>x</b>")
    get workshop_configuration_path(tab: "designs")
    assert_includes response.body, "boom &lt;script&gt;alert(1)&lt;/script&gt; &lt;b&gt;x&lt;/b&gt;"
    assert_not_includes response.body, "<script>alert(1)</script>"
  end

  test "a refused save starts nothing and says why" do
    assert_no_enqueued_jobs(only: Designs::InitializeRepoJob) do
      patch workshop_configuration_path, params: { tab: "designs", project: {
        designs_enabled: "1", design_repo: "not a repo", design_repo_token: "dt" } }
    end
    @project.reload
    assert_not @project.designs_enabled?
    assert_nil @project.design_repo_token
    assert_nil @project.design_repo_status
    assert_equal "Design repo must look like owner/name", flash[:alert]
    assert_no_match(/Designs settings saved/, flash[:clar_toast].to_s)
  end

  test "the app's own repository is refused as the design repo, and starts nothing" do
    @project.update!(github_repo: "acme/app")
    assert_no_enqueued_jobs(only: Designs::InitializeRepoJob) do
      patch workshop_configuration_path, params: { tab: "designs", project: {
        designs_enabled: "1", design_repo: "acme/app", design_repo_token: "dt" } }
    end
    @project.reload
    assert_nil @project.design_repo
    assert_nil @project.design_repo_status
    assert_equal "Design repo must be a different repository from the app's", flash[:alert]
  end

  test "switching Designs on without a token queues nothing" do
    assert_no_enqueued_jobs(only: Designs::InitializeRepoJob) do
      patch workshop_configuration_path, params: { tab: "designs", project: {
        designs_enabled: "1", design_repo: "acme/designs", design_repo_token: "" } }
    end
    assert @project.reload.designs_enabled?
    assert_nil @project.design_repo_status
  end

  test "saving a repo that is already ready does not set it up again" do
    ready_project
    assert_no_enqueued_jobs(only: Designs::InitializeRepoJob) do
      patch workshop_configuration_path, params: { tab: "designs", project: {
        designs_enabled: "1", design_repo: "acme/designs", design_repo_token: "", design_base_kit: "plain" } }
    end
    @project.reload
    assert_equal "ready", @project.design_repo_status
    assert_equal "plain", @project.design_base_kit
  end

  test "pasting the same repo as a URL is not a change" do
    ready_project
    assert_no_enqueued_jobs(only: Designs::InitializeRepoJob) do
      patch workshop_configuration_path, params: { tab: "designs", project: {
        design_repo: "https://github.com/acme/designs.git" } }
    end
    assert_equal "ready", @project.reload.design_repo_status
  end

  test "pointing a ready project at another repo sets it up again" do
    ready_project
    assert_enqueued_with(job: Designs::InitializeRepoJob, args: [ @project.id ]) do
      patch workshop_configuration_path, params: { tab: "designs", project: { design_repo: "acme/other" } }
    end
    @project.reload
    assert_equal "acme/other", @project.design_repo
    assert_equal "initializing", @project.design_repo_status
  end

  # A status describes the repo it was made for. Repointed with Designs off, the
  # old repo's Ready (and its link into the old previews) must not survive, or
  # switching Designs on later finds a repo that looks done and queues nothing.
  test "pointing a ready project at another repo with Designs off drops its Ready, and switching Designs on later sets the new repo up" do
    ready_project

    assert_no_enqueued_jobs(only: Designs::InitializeRepoJob) do
      patch workshop_configuration_path, params: { tab: "designs", project: {
        designs_enabled: "0", design_repo: "acme/other", design_repo_token: "" } }
    end
    @project.reload
    assert_equal "acme/other", @project.design_repo
    assert_nil @project.design_repo_status
    get workshop_configuration_path(tab: "designs")
    assert_select "[data-design-status]", /Not set up/
    assert_select "a", text: /Open master preview/, count: 0

    assert_enqueued_with(job: Designs::InitializeRepoJob, args: [ @project.id ]) do
      patch workshop_configuration_path, params: { tab: "designs", project: {
        designs_enabled: "1", design_repo: "acme/other", design_repo_token: "" } }
    end
    assert_equal "initializing", @project.reload.design_repo_status
  end

  test "a failure belongs to the repo that failed, so pointing Designs at another repo clears it" do
    @project.update!(design_repo: "acme/designs", design_repo_token: "dt",
                     design_repo_status: "error", design_repo_error: "git push failed: permission denied")

    patch workshop_configuration_path, params: { tab: "designs", project: { design_repo: "acme/other" } }

    @project.reload
    assert_nil @project.design_repo_status
    assert_nil @project.design_repo_error
    get workshop_configuration_path(tab: "designs")
    assert_select "[data-design-status]", /Not set up/
    assert_no_match(/permission denied/, response.body)
  end

  test "clearing the repo while Designs is on drops its Ready as well" do
    ready_project

    assert_no_enqueued_jobs(only: Designs::InitializeRepoJob) do
      patch workshop_configuration_path, params: { tab: "designs", project: { design_repo: "" } }
    end
    @project.reload
    assert_equal "", @project.design_repo
    assert_nil @project.design_repo_status
  end

  test "a repository that cannot be forgiven says how it should look" do
    patch workshop_configuration_path, params: { tab: "designs", project: { design_repo: "git@github.com:acme/designs.git" } }
    assert_redirected_to workshop_configuration_path(tab: "designs")
    follow_redirect!
    assert_select ".clar-badge-danger", text: /Design repo must look like owner\/name/
  end

  test "saving after a failed setup tries again and clears the error" do
    @project.update!(designs_enabled: true, design_repo: "acme/designs", design_repo_token: "dt",
                     design_repo_status: "error", design_repo_error: "git push failed: permission denied")
    assert_enqueued_with(job: Designs::InitializeRepoJob, args: [ @project.id ]) do
      patch workshop_configuration_path, params: { tab: "designs", project: { design_repo_token: "better-token" } }
    end
    @project.reload
    assert_equal "better-token", @project.design_repo_token
    assert_equal "initializing", @project.design_repo_status
    assert_nil @project.design_repo_error
  end

  test "the Preview links card posts its own form, outside the settings form" do
    get workshop_configuration_path(tab: "designs")
    assert_select "form[action=?] button", workshop_rotate_design_preview_token_configuration_path, text: "Rotate preview links"
    assert_select "form form", false, "HTML forbids nested forms"
  end

  test "rotating moves the previews already published, so the old links die at once" do
    with_preview_root do |root|
      @project.update!(design_preview_token: "old-token-old-token-old-token-12")
      FileUtils.mkdir_p(root.join("old-token-old-token-old-token-12/master"))
      File.write(root.join("old-token-old-token-old-token-12/master/index.html"), "<h1>Home</h1>")

      post workshop_rotate_design_preview_token_configuration_path

      token = @project.reload.design_preview_token
      assert_not_equal "old-token-old-token-old-token-12", token
      assert_not root.join("old-token-old-token-old-token-12").exist?
      assert_equal "<h1>Home</h1>", root.join(token, "master/index.html").read
      assert_match(/stopped working|no longer work/, flash[:clar_toast])
    end
  end

  # Rotating the links of a project that never turned Designs on must not
  # give it a folder; one that has a folder is rotated under the repo's lock.
  test "rotating gives a project without a design folder none, and uses the lock where there is one" do
    with_preview_root do
      post workshop_rotate_design_preview_token_configuration_path
      assert_nil @project.reload.workspace_dir

      Dir.mktmpdir("designs-workspace") do |workspace|
        @project.update_columns(workspace_dir: workspace)
        post workshop_rotate_design_preview_token_configuration_path
        assert File.exist?(File.join(workspace, "design-repo.lock")), "the rotation ran inside the repo's lock"
      end
    end
  end

  # A web thread must not wait behind a job holding the repo (a set-up can take
  # minutes): the rotation is refused at once, and nothing changes.
  test "rotating while a job holds the design repo changes nothing and says to try again" do
    with_preview_root do |root|
      Dir.mktmpdir("designs-workspace") do |workspace|
        @project.update_columns(workspace_dir: workspace, design_preview_token: "old-token-old-token-old-token-12")
        FileUtils.mkdir_p(root.join("old-token-old-token-old-token-12/master"))

        File.open(File.join(workspace, "design-repo.lock"), File::RDWR | File::CREAT) do |job|
          job.flock(File::LOCK_EX)
          post workshop_rotate_design_preview_token_configuration_path
        end

        assert_redirected_to workshop_configuration_path(tab: "designs")
        assert_equal "The design repo is busy — try again in a minute.", flash[:clar_toast]
        assert_equal "old-token-old-token-old-token-12", @project.reload.design_preview_token
        assert root.join("old-token-old-token-old-token-12/master").exist?
      end
    end
  end

  private

  def ready_project
    @project.update!(designs_enabled: true, design_repo: "acme/designs", design_repo_token: "dt",
                     design_repo_status: "ready", design_preview_token: "t0k")
  end

  def with_preview_root
    root = Dir.mktmpdir("designs-preview")
    previous = ENV["DESIGNS_PREVIEW_ROOT"]
    ENV["DESIGNS_PREVIEW_ROOT"] = root
    yield Pathname(root)
  ensure
    previous ? ENV["DESIGNS_PREVIEW_ROOT"] = previous : ENV.delete("DESIGNS_PREVIEW_ROOT")
    FileUtils.remove_entry(root) if root && File.exist?(root)
  end
end
