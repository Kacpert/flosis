require "test_helper"

class Designs::TemplateTest < ActiveSupport::TestCase
  include DesignRepoTestHelper

  setup do
    @dir = Dir.mktmpdir("template")
    @project = projects(:jira_project)
  end
  teardown { FileUtils.remove_entry(@dir) }

  test "renders exactly the six places the leak guard allows, and passes it" do
    Designs::Template.render_into(@dir, project: @project)
    assert_equal %w[README.md components design_system designs index.html runtime], Dir.children(@dir).sort
    changes = Dir.glob("**/*", base: @dir).select { |p| File.file?(File.join(@dir, p)) }
                 .map { |p| Designs::Repo::Change.new(path: p, added_text: File.read(File.join(@dir, p))) }
    assert_empty Designs::LeakGuard.new.check(changes)
  end

  test "the README names the project and the conventions a developer needs" do
    Designs::Template.render_into(@dir, project: @project)
    readme = File.read(File.join(@dir, "README.md"))
    [ @project.name, "design/<KEY>", "wip/<KEY>", "approved/<KEY>/<n>", "python3 -m http.server 8000", "?ctx=" ].each do |fact|
      assert_includes readme, fact
    end
  end

  test "the Tailwind kit ships the vendored browser build and a Tailwind theme" do
    @project.design_base_kit = "tailwind4"
    Designs::Template.render_into(@dir, project: @project)
    assert_equal({ "kit" => "tailwind4" }, JSON.parse(File.read(File.join(@dir, "runtime/config.json"))))
    assert_includes File.read(File.join(@dir, "runtime/kit.js")), "tailwindcss"
    assert_includes File.read(File.join(@dir, "design_system/theme.css")), "@theme"
    assert_not File.exist?(File.join(@dir, "runtime/kits"))
  end

  test "the plain kit ships no Tailwind at all" do
    @project.design_base_kit = "plain"
    Designs::Template.render_into(@dir, project: @project)
    assert_not File.exist?(File.join(@dir, "runtime/kit.js"))
    assert_not_includes File.read(File.join(@dir, "design_system/theme.css")), "@theme"
  end

  test "every page loads the runtime and includes the shared nav" do
    Designs::Template.render_into(@dir, project: @project)
    %w[index.html design_system/index.html components/index.html designs/index.html].each do |page|
      html = File.read(File.join(@dir, page))
      assert_match %r{<script src="(\.\./)?runtime/flosis\.js"}, html, page
      assert_includes html, %(<x-include src="runtime/nav.html"), page
    end
  end

  # Every file name the template holds for one kit only, and every ERB source,
  # must be gone from a rendered repo: what is left is what gets committed.
  test "a rendered repo holds one theme, no kits folder and no ERB source, whichever the kit" do
    Project::DESIGN_BASE_KITS.each do |kit|
      Dir.mktmpdir("template-#{kit}") do |dir|
        @project.design_base_kit = kit
        Designs::Template.render_into(dir, project: @project)
        files = Dir.glob("**/*", base: dir)
        assert_equal [ "design_system/theme.css" ], files.grep(/theme\.css/), kit
        assert_empty files.grep(%r{\.erb\z|\Aruntime/kits}), kit
        assert_equal({ "kit" => kit }, JSON.parse(File.read(File.join(dir, "runtime/config.json"))), kit)
      end
    end
  end

  # The design-system page's swatch reaches the primary colour the kit's own
  # way: a Tailwind utility, or the custom property in plain CSS.
  test "the design-system swatch uses a Tailwind utility only in the Tailwind kit" do
    @project.design_base_kit = "tailwind4"
    Designs::Template.render_into(@dir, project: @project)
    assert_includes File.read(File.join(@dir, "design_system/index.html")), "bg-primary text-on-primary"

    Dir.mktmpdir("template-plain") do |dir|
      @project.design_base_kit = "plain"
      Designs::Template.render_into(dir, project: @project)
      page = File.read(File.join(dir, "design_system/index.html"))
      assert_includes page, "background: var(--color-primary)"
      assert_not_includes page, "bg-primary"
    end
  end

  # The kit names files in the template, so one it has no theme for is refused
  # before anything is written: a repo started without a theme stays that way.
  test "a kit the template has no theme for is refused, and nothing is written" do
    [ "bootstrap5", "../../config/master.key", "" ].each do |kit|
      @project.design_base_kit = kit
      assert_raises(ArgumentError, kit) { Designs::Template.render_into(@dir, project: @project) }
      assert_empty Dir.children(@dir), kit
    end
  end

  # The publisher drops whatever is not a static web file (no extension, a
  # dotfile, an extension it does not serve), so a template file it drops
  # would vanish from every preview without a word.
  test "every file of a rendered repo is published to the preview host" do
    preview_root = Dir.mktmpdir("preview")
    ENV["DESIGNS_PREVIEW_ROOT"] = preview_root
    with_design_remote(@project) do |repo, _|
      repo.ensure_clone!
      Designs::Template.render_into(repo.root, project: repo.project)
      rendered = Dir.glob("**/*", base: repo.root).select { |p| File.file?(repo.root.join(p)) }.sort
      repo.stage_all!(repo.root)
      repo.commit!(repo.root, message: "Start the design repo")

      slot = Designs::Publisher.new(repo.project, repo).publish!("master", "master")
      assert_includes rendered, "runtime/kit.js"
      assert_equal rendered, Dir.glob("**/*", base: slot).select { |p| slot.join(p).file? }.sort
    end
  ensure
    ENV.delete("DESIGNS_PREVIEW_ROOT")
    FileUtils.remove_entry(preview_root) if preview_root
  end
end
