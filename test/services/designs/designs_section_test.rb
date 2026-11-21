require "test_helper"

# The Designs section of a task's description (Accept designs, 2026-11-21):
# Flosis writes it from the task's accepted copy, never the AI.
class Designs::DesignsSectionTest < ActiveSupport::TestCase
  LINK = "https://preview.example/test-workspace/elvium/SCRUM-70/design".freeze

  setup do
    @root = Pathname(Dir.mktmpdir("preview"))
    ENV["DESIGNS_PREVIEW_ROOT"] = @root.to_s
    ENV["DESIGNS_PREVIEW_URL"] = "https://preview.example"
    @project = projects(:jira_project)
    @project.update!(design_preview_token: "t0k", design_repo: "acme/designs")
    @task = @project.tasks.create!(name: "SCRUM-70 Add token calculations", external_reference: "SCRUM-70", external_type: "jira")
  end

  teardown do
    ENV.delete("DESIGNS_PREVIEW_ROOT")
    ENV.delete("DESIGNS_PREVIEW_URL")
    FileUtils.remove_entry(@root)
  end

  def accept!(sha, at: Time.current)
    DesignMerge.create!(project: @project, task: @task, sha: sha * 40, title: "t", branch: "design/x", how: "manual",
                        merged_at: at, slot: "accepted/7")
  end

  # The accepted copy as Publisher leaves it: its screens and what changed.
  def publish(screens, own, through = {})
    folder = @root.join("t0k", "accepted/7", "__flosis")
    FileUtils.mkdir_p(folder)
    contexts = screens.map(&:first).uniq.map { |id| { id: id, name: id.tr("-", " ").capitalize } }
    File.write(folder.join("screens.json"), { contexts: contexts,
                                              screens: screens.map { |ctx, id, name| { id: id, context: ctx, name: name } } }.to_json)
    File.write(folder.join("changes.json"), { own: own, through: through }.to_json)
  end

  def screen_link(context, id) = "#{LINK}/designs/#{context}/#{id}.html"

  test "the section lists the merge commit, new and updated screens per context, and the through line" do
    accept!("a")
    publish([ [ "admin", "plans", "Plans" ], [ "admin", "bugs", "Bug Reporting" ], [ "flosis-admin", "models", "Models & prices" ] ],
            [ [ "admin", "plans", "new" ], [ "admin", "bugs", "updated" ], [ "flosis-admin", "models", "new" ] ],
            { "sidebar" => [ [ "admin", "x" ] ], "chat-panel" => [ [ "admin", "y" ] ], "pipeline-header" => [], "process-header" => [],
              "bug-row" => [], "estimate-row" => [] })

    assert_equal [
      "**Designs** · [Open the designs](#{LINK}) · merge commit [aaaaaaa](https://github.com/acme/designs/commit/#{'a' * 40})",
      "- New (2): Admin › [Plans](#{screen_link('admin', 'plans')}) · Flosis admin › [Models & prices](#{screen_link('flosis-admin', 'models')})",
      "- Updated (1): Admin › [Bug Reporting](#{screen_link('admin', 'bugs')})",
      "- Through shared components: sidebar, chat panel, pipeline header, process header and 2 more"
    ], Designs::DesignsSection.build(@task).lines.map(&:chomp)
  end

  test "screens sharing a name before the dash are grouped" do
    accept!("a")
    publish([ [ "admin", "profile", "Profile Settings" ], [ "admin", "profile-saved", "Profile Settings — saved" ],
              [ "admin", "profile-two", "Profile Settings — in two organizations" ],
              [ "admin", "profile-error", "Profile Settings — wrong current password" ],
              [ "admin", "consumption", "Consumption — this month" ], [ "admin", "consumption-all", "Consumption — all time" ],
              [ "admin", "configuration-off", "Configuration — AI costs hidden for everyone" ] ],
            [ [ "admin", "configuration-off", "new" ], [ "admin", "consumption", "new" ], [ "admin", "consumption-all", "new" ],
              [ "admin", "profile", "updated" ], [ "admin", "profile-error", "updated" ], [ "admin", "profile-saved", "updated" ],
              [ "admin", "profile-two", "updated" ] ])
    lines = Designs::DesignsSection.build(@task).lines.map(&:chomp)

    assert_equal "- New (3): Admin › [Configuration — AI costs hidden for everyone](#{screen_link('admin', 'configuration-off')}), " \
                 "Consumption — [this month](#{screen_link('admin', 'consumption')}), [all time](#{screen_link('admin', 'consumption-all')})",
                 lines[1]
    assert_equal "- Updated (4): Admin › [Profile Settings](#{screen_link('admin', 'profile')}) (+3 states)", lines[2]
  end

  test "two acceptances list both merge commits, oldest first" do
    accept!("a", at: 2.days.ago)
    accept!("b", at: 1.day.ago)
    publish([ [ "admin", "plans", "Plans" ] ], [ [ "admin", "plans", "new" ] ])

    assert_includes Designs::DesignsSection.build(@task).lines.first,
                    "merge commits [aaaaaaa](https://github.com/acme/designs/commit/#{'a' * 40}), [bbbbbbb](https://github.com/acme/designs/commit/#{'b' * 40})"
  end

  test "no acceptance, no section" do
    assert_nil Designs::DesignsSection.build(@task)
  end

  SECTION = "**Designs** · [Open the designs](https://x.test/d)\n- New (1): Admin › [Plans](https://x.test/p)".freeze

  test "insert puts it under the intro, after a heading or without one, and replaces it in place later" do
    assert_equal "## Title\n\nIntro.\n\n#{SECTION}\n\n**Rules**\n\n- one",
                 Designs::DesignsSection.insert("## Title\n\nIntro.\n\n**Rules**\n\n- one", SECTION)
    assert_equal "Intro.\n\n#{SECTION}\n\n## Feature\n\n- one",
                 Designs::DesignsSection.insert("Intro.\n\n## Feature\n\n- one", SECTION)

    moved = "## Title\n\nIntro.\n\n**Rules**\n\n**Designs** · old\n- New (9): old\n\n- one"
    newer = "**Designs** · [Open the designs](https://x.test/d2)\n- Updated (1): Admin › [Plans](https://x.test/p)"
    assert_equal "## Title\n\nIntro.\n\n**Rules**\n\n#{newer}\n\n- one", Designs::DesignsSection.insert(moved, newer)
  end

  test "strip removes it from Markdown and from the editor's HTML" do
    assert_equal "## Title\n\nIntro.\n\n**Rules**", Designs::DesignsSection.strip("## Title\n\nIntro.\n\n#{SECTION}\n\n**Rules**")
    html = "<h2>Title</h2><p>Intro.</p><p><b>Designs</b> · <a href=\"https://x.test/d\">Open the designs</a></p>" \
           "<p>- New (1): Admin › <a href=\"https://x.test/p\">Plans</a></p><p><b>Rules</b></p>"
    assert_equal "## Title\n\nIntro.\n\n**Rules**", Designs::DesignsSection.strip(html)
    assert_equal "", Designs::DesignsSection.strip(nil)
  end

  test "with_section puts it back only when the link is missing" do
    accept!("a")
    publish([ [ "admin", "plans", "Plans" ] ], [ [ "admin", "plans", "new" ] ])
    section = Designs::DesignsSection.build(@task)

    assert_equal "Intro.\n\n#{section}\n\n## Feature", Designs::DesignsSection.with_section(@task, "Intro.\n\n## Feature")
    kept = "Intro with [the designs](#{LINK})."
    assert_equal kept, Designs::DesignsSection.with_section(@task, kept)
    assert_equal "<p>Intro.</p>", Designs::DesignsSection.with_section(@project.tasks.create!(name: "Other"), "<p>Intro.</p>")
    assert_equal "Intro.\n\n#{section}", Designs::DesignsSection.with_section(@task, "<p>Intro.</p>")
  end
  # Review (re-graded): a section with no screens is its first line alone; the
  # description's own list after it is not part of it.
  test "a section with only its first line never swallows the list after it" do
    text = "Intro.\n\n**Designs** · [Open the designs](https://x.test/d) · merge commit [a](https://x.test/c)\n\n- one\n- two"

    assert_equal "Intro.\n\n- one\n- two", Designs::DesignsSection.strip(text)
    assert_equal "Intro.\n\n#{SECTION}\n\n- one\n- two", Designs::DesignsSection.insert(text, SECTION)
  end
end
