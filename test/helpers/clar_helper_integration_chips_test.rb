require "test_helper"

# The topbar chips are the one place anyone looks to see whether the
# integrations are alive. Green used to mean "somebody filled the field in",
# so an expired Figma token stayed green and the AI broke the news to a client.
class ClarHelperIntegrationChipsTest < ActionView::TestCase
  include ClarHelper

  setup do
    @workspace = workspaces(:one)
    Current.workspace = @workspace
    @workspace.update!(github_repo: "acme/widgets", figma_read_enabled: true)
  end

  teardown { Current.workspace = nil }

  # The helper reads the workshop project for Jira; these tests are about the
  # other three, so keep it out of the way.
  def current_workshop_project = nil

  # Not named `chip` — that would shadow the helper's own private chip builder.
  def find_chip(label) = integration_chips.find { |c| c[:label] == label }

  test "a working integration is on and not broken" do
    @workspace.update!(github_status_ok: true)

    assert find_chip("GitHub")[:on]
    assert_not find_chip("GitHub")[:broken]
    assert_equal "GitHub · connected", find_chip("GitHub")[:title]
  end

  test "a failing integration is marked broken and says why on hover" do
    @workspace.update!(figma_status_ok: false, figma_status_error: "401 Unauthorized — Token has expired")

    figma = find_chip("Figma")
    assert figma[:broken], "an expired token must not read as connected"
    assert_equal "Figma · not working — 401 Unauthorized — Token has expired", figma[:title]
  end

  test "an integration nobody configured is neither on nor broken" do
    @workspace.update!(figma_read_enabled: false, figma_status_ok: false, figma_status_error: "boom")

    figma = find_chip("Figma")
    assert_not figma[:on]
    assert_not figma[:broken], "nothing is broken about an integration you never set up"
    assert_equal "Figma · not connected", figma[:title]
  end

  test "configured but never checked reads as connected, not as broken" do
    @workspace.update!(github_status_ok: nil, github_status_error: nil)

    assert_not find_chip("GitHub")[:broken]
    assert_match(/not checked yet/, find_chip("GitHub")[:title])
  end

  # A webhook URL is write-only — there is nothing to ask it — so Discord says
  # so rather than implying it was verified.
  test "Discord admits it is not health-checked" do
    @workspace.update!(discord_channel_id: "123")

    assert find_chip("Discord")[:on]
    assert_not find_chip("Discord")[:broken]
    assert_match(/not health-checked/, find_chip("Discord")[:title])
  end
end
