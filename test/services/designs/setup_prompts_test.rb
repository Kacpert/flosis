require "test_helper"

# Workshop Designs v2: the setup's phase prompts and the repo's README speak of
# the v2 layout only (design-system/, a folder per context, no manifests).
class Designs::SetupPromptsTest < ActiveSupport::TestCase
  V1_WORDS = [ "contexts.json", "?ctx=", "wip/", "design_system/", "manifest" ].freeze

  test "no phase prompt speaks of v1's layout, and the screens phase writes a folder per context" do
    Designs::SetupPrompts::SEEDS.each_value do |seed|
      V1_WORDS.each { |word| assert_not_includes seed[:body], word, "#{seed[:key]} mentions #{word}" }
    end
    assert_includes Designs::SetupPrompts::SEEDS.fetch("designs")[:body], "designs/<context>/<screen>.html"
    assert_includes Designs::SetupPrompts::SEEDS.fetch("design_system")[:body], "mismatch"
  end

  test "a new repo's README speaks of threads and context folders, not of v1's branches" do
    Dir.mktmpdir("readme") do |dir|
      Designs::Template.render_into(dir, project: projects(:jira_project))
      readme = File.read(File.join(dir, "README.md"))
      [ "contexts.json", "?ctx=", "wip/", "approved/", "data-ctx" ].each { |word| assert_not_includes readme, word, word }
      [ "design/", "designs/<context>/" ].each { |word| assert_includes readme, word, word }
    end
  end

  test "a setup turn is told the stack and the app's repositories" do
    project = projects(:jira_project)
    project.update!(designs_framework: "html", designs_ui_system: "tailwind", designs_ui_version: "4",
                    design_app_repos: [ { "role" => "Frontend", "repo" => "acme/app@production" } ])
    project.design_setups.create!(status: "active", phase: "design_system", step: 3, started_by: users(:one))
    session = ChatSession.create!(project: project, workspace: project.workspace, user: users(:one), purpose: "designs_setup",
                                  claude_session_id: SecureRandom.uuid, codebase_path: "/tmp")
    message = Designs::Subject.for(session).turn_message("Recreate the design system")
    [ "HTML + CSS", "Tailwind 4", "Frontend: acme/app@production" ].each { |fact| assert_includes message, fact }
  end
end
