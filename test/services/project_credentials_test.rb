require "test_helper"

# One place answers "what credentials does this project use". The workspace
# fallback is gone: a second client's keys have nowhere to fall back TO, and a
# silent fallback to the first client's token is worse than a blank field.
class ProjectCredentialsTest < ActiveSupport::TestCase
  setup do
    @workspace = workspaces(:one)
    @project = projects(:jira_project)
    @project.update!(external_reference: "DEV")
  end

  def with_cli_token(token)
    original = FigmaClient.method(:cli_token)
    FigmaClient.define_singleton_method(:cli_token) { token }
    yield
  ensure
    FigmaClient.define_singleton_method(:cli_token, original)
  end

  test "reads the project's own keys" do
    @project.update!(github_repo: "acme/own", github_token: "pt", figma_token: "ft",
                     figma_read_enabled: true)
    creds = ProjectCredentials.new(@project)

    assert_equal "acme/own", creds.github_repo
    assert_equal "pt", creds.github_token
    assert_equal "ft", creds.figma_token
    assert creds.figma_configured?
  end

  # There is no workspace key left to borrow; the resolver reads the project
  # and then ENV, and nothing in between.
  test "resolves to nothing when the project itself has no key" do
    @project.update!(github_repo: nil, github_token: nil)
    creds = ProjectCredentials.new(@project)

    assert_nil creds.github_token
    assert_nil creds.github_repo
    assert_not @workspace.respond_to?(:github_token), "the workspace is carrying credentials again"
  end

  test "jira falls back to ENV when project is blank" do
    ENV["JIRA_DOMAIN"] = "env.atlassian.net"
    ENV["JIRA_EMAIL"] = "env@example.com"
    ENV["JIRA_API_TOKEN"] = "env_token"
    creds = ProjectCredentials.new(@project)
    assert_equal "env.atlassian.net", creds.jira_site
    assert_equal "env@example.com", creds.jira_email
    assert_equal "env_token", creds.jira_api_token
  ensure
    %w[JIRA_DOMAIN JIRA_EMAIL JIRA_API_TOKEN].each { |k| ENV.delete(k) }
  end

  test "project jira overrides ENV" do
    ENV["JIRA_DOMAIN"] = "env.atlassian.net"
    @project.update!(jira_site: "proj.atlassian.net", jira_email: "p@x.com", jira_api_token: "pt")
    creds = ProjectCredentials.new(@project)
    assert_equal "proj.atlassian.net", creds.jira_site
    assert_equal "p@x.com", creds.jira_email
    assert_equal "pt", creds.jira_api_token
  ensure
    ENV.delete("JIRA_DOMAIN")
  end

  # The CLI already runs off the machine's own key, so a project that never set
  # one keeps working exactly as it does today.
  test "the AI key falls back to the environment" do
    @project.update!(anthropic_api_key: nil)
    ENV["ANTHROPIC_API_KEY"] = "env-key"

    assert_equal "env-key", ProjectCredentials.new(@project).anthropic_api_key
  ensure
    ENV.delete("ANTHROPIC_API_KEY")
  end

  test "the project's own AI key wins over the environment" do
    @project.update!(anthropic_api_key: "project-key")
    ENV["ANTHROPIC_API_KEY"] = "env-key"

    assert_equal "project-key", ProjectCredentials.new(@project).anthropic_api_key
  ensure
    ENV.delete("ANTHROPIC_API_KEY")
  end

  # Designs works on a client's repository, so it runs on the client's own key
  # and on nothing else: the machine's key and login are not theirs to use.
  test "designs runs on the project's own AI key" do
    @project.update!(anthropic_api_key: "project-key")

    with_env("ANTHROPIC_API_KEY" => "env-key") do
      assert_equal "project-key", ProjectCredentials.new(@project).designs_api_key
    end
  end

  test "a blank project key is no designs key, whatever the environment holds" do
    with_env("ANTHROPIC_API_KEY" => "env-key") do
      [ nil, "", "  " ].each do |blank|
        @project.update!(anthropic_api_key: blank)
        assert_nil ProjectCredentials.new(@project).designs_api_key, blank.inspect
      end
    end
  end

  test "jira_key comes from external_reference" do
    assert_equal "DEV", ProjectCredentials.new(@project).jira_key
  end

  test "configured predicates" do
    @project.update!(github_repo: "p/r", github_token: "t",
                     jira_site: "s", jira_email: "e", jira_api_token: "jt",
                     figma_read_enabled: true, figma_token: "ft")
    creds = ProjectCredentials.new(@project)
    assert creds.github_configured?
    assert creds.jira_configured?
    assert creds.figma_configured?
  end

  # A token nobody asked the AI to use is not a working integration — the
  # Figma chip and the MCP server both hang off the toggle, not the key alone.
  test "figma is not configured while the project has not enabled reading" do
    @project.update!(figma_read_enabled: false, figma_token: "ft")

    assert_not ProjectCredentials.new(@project).figma_configured?
  end

  # The CLI's own key is the fallback, and it has to be the SAME answer the
  # health check gets: the chips went green off the machine's key while the
  # .mcp.json the AI ran with had no Figma server in it at all.
  test "figma falls back to the CLI's token, and is configured exactly when there is one" do
    @project.update!(figma_read_enabled: true, figma_token: nil)

    with_cli_token("cli-key") do
      assert_equal "cli-key", ProjectCredentials.new(@project).figma_token
      assert ProjectCredentials.new(@project).figma_configured?
    end

    with_cli_token(nil) do
      assert_nil ProjectCredentials.new(@project).figma_token
      assert_not ProjectCredentials.new(@project).figma_configured?
    end
  end

  test "the project's own figma token wins over the CLI's" do
    @project.update!(figma_read_enabled: true, figma_token: "own")

    with_cli_token("cli-key") { assert_equal "own", ProjectCredentials.new(@project).figma_token }
  end


  # What the leak guard keeps out of a design repo. Every encrypted column is
  # in it, so a credential added to the model later is guarded without anyone
  # remembering the guard. The machine's own credentials are ENV and the CLI's
  # config here; both are replaced, so no real one is read or printed.
  test "all_secrets holds every credential the project stores" do
    stored = Project.encrypted_attributes.index_with { |attribute| "stored-#{attribute}" }
    @project.update!(stored)
    with_env("JIRA_API_TOKEN" => nil, "ANTHROPIC_API_KEY" => nil) do
      with_cli_token(nil) do
        assert_equal stored.values.sort, ProjectCredentials.new(@project).all_secrets.sort
      end
    end
  end

  # They are the fallbacks the AI is handed, whatever the project stores.
  test "all_secrets adds the machine's own credentials, each once, and no blanks" do
    @project.update!(github_token: nil, jira_api_token: "shared-jira-token", figma_token: "",
                     anthropic_api_key: nil, design_repo_token: nil)
    with_env("JIRA_API_TOKEN" => "shared-jira-token", "ANTHROPIC_API_KEY" => "machine-anthropic-key") do
      with_cli_token("machine-figma-token") do
        assert_equal %w[machine-anthropic-key machine-figma-token shared-jira-token],
                     ProjectCredentials.new(@project).all_secrets.sort
      end
    end
    with_env("JIRA_API_TOKEN" => "  ", "ANTHROPIC_API_KEY" => "") do
      with_cli_token(nil) do
        assert_equal %w[shared-jira-token], ProjectCredentials.new(@project).all_secrets
      end
    end
  end

  test "not configured when creds missing everywhere" do
    @project.update!(github_repo: nil, github_token: nil, figma_token: nil)
    %w[JIRA_DOMAIN JIRA_EMAIL JIRA_API_TOKEN].each { |k| ENV.delete(k) }
    creds = ProjectCredentials.new(@project)
    assert_not creds.github_configured?
    assert_not creds.jira_configured?
    assert_not creds.figma_configured?
  end
end
