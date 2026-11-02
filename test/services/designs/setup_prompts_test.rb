require "test_helper"

# The setup's phase prompts (the Designs setup, feature by feature): a map, the
# design system and one feature at a time. They and the repo's README speak of
# the v2 layout only (design-system/, a folder per context, no manifests).
class Designs::SetupPromptsTest < ActiveSupport::TestCase
  V1_WORDS = [ "contexts.json", "?ctx=", "wip/", "design_system/", "manifest" ].freeze

  test "no phase prompt speaks of v1's layout, and the screens phase writes a folder per context" do
    Designs::SetupPrompts::SEEDS.each_value do |seed|
      V1_WORDS.each { |word| assert_not_includes seed[:body], word, "#{seed[:key]} mentions #{word}" }
    end
    assert_includes Designs::SetupPrompts::SEEDS.fetch("feature")[:body], "designs/<context>/<screen>.html"
    assert_includes Designs::SetupPrompts::SEEDS.fetch("design_system")[:body], "mismatch"
  end

  test "a run has a map, a design system and a feature phase" do
    keys = %w[map design_system feature].map { |phase| Designs::SetupPrompts::SEEDS.fetch(phase)[:key] }
    assert_equal %w[setup-map setup-design-system setup-feature], keys
  end

  test "the map is saved with its tool, the app shell first" do
    body = Designs::SetupPrompts::SEEDS.fetch("map")[:body]
    [ "save_features", "app shell", "open", "contexts" ].each { |word| assert_includes body, word, word }
  end

  test "a feature is built from the app, checked against it, and touches only its own records" do
    body = Designs::SetupPrompts::SEEDS.fetch("feature")[:body]
    [ "fill_form", "compare", "check_design", "progress", "only what you created", "never sign out", "<missing>" ].each do |word|
      assert_includes body, word, word
    end
  end

  test "the design system reads the app's styles in the browser, not a crawl" do
    body = Designs::SetupPrompts::SEEDS.fetch("design_system")[:body]
    assert_includes body, "browser"
    assert_not_includes body, "crawl"
  end

  # The guard refuses twelve words in a row of what a turn is given: a setup
  # prompt that quoted the template would get every setup turn refused.
  test "the files of a new design repo hold no passage of a setup prompt" do
    texts = Designs::SetupPrompts::SEEDS.values.map { |seed| seed[:body] }
    guard = Designs::LeakGuard.new(forbidden_texts: texts, flosis_files: true)
    Dir.mktmpdir("prompt") do |dir|
      Designs::Template.render_into(dir, project: projects(:jira_project))
      changes = Dir.glob("**/*", base: dir).select { |path| File.file?(File.join(dir, path)) }
                   .map { |path| Designs::Repo::Change.new(path: path, added_text: File.read(File.join(dir, path))) }
      assert_empty guard.check(changes)
    end
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
