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
    [ @project.name, "design/<KEY>", "wip/<KEY>", "approved/<KEY>/<n>", "python3 -m http.server 8000", "?ctx=",
      "`nav.html`", "`[A-Za-z0-9_-]`" ].each do |fact|
      assert_includes readme, fact
    end
  end

  # Ruling R25: components read var(--color-*) in their own CSS, and a plain
  # @theme emits only the variables that some utility on the page uses.
  test "the Tailwind theme makes every token a CSS variable, used or not" do
    @project.design_base_kit = "tailwind4"
    Designs::Template.render_into(@dir, project: @project)
    assert_match(/^@theme static \{$/, File.read(File.join(@dir, "design_system/theme.css")))
  end

  # The build is vendored unmodified (see Designs::Template): a changed byte is
  # an upgrade, which moves this pin and TAILWIND_VERSION together, or a mistake.
  # Never assert_includes on the build: a failure would print all of it.
  test "the vendored Tailwind build is the one its provenance names" do
    kit = Designs::Template::SOURCE.join("runtime/kits/tailwind4.js")
    assert_equal "29edc4b76dac05a8c27bb9bdd0ec6d6506a2f55c1db24f11fa5b7f509142e6bf", Digest::SHA256.file(kit).hexdigest
    assert kit.read.include?(%("#{Designs::Template::TAILWIND_VERSION}")), "the build declares another version"

    @project.design_base_kit = "tailwind4"
    Designs::Template.render_into(@dir, project: @project)
    assert_includes File.read(File.join(@dir, "README.md")), "version #{Designs::Template::TAILWIND_VERSION}"
  end

  # The runtime's own rule is that nothing fails silently, and a config.json
  # naming no kit it knows left the page unstyled without a word. It runs here
  # in Node, with a stand-in for the page, so it is skipped where there is none.
  test "the runtime shows its error box for a config.json without a kit it knows, and none for a kit it knows" do
    skip "Node is not installed" unless system("node", "--version", out: File::NULL, err: File::NULL)

    Project::DESIGN_BASE_KITS.each { |kit| assert_equal [], runtime_errors("kit" => kit), kit }
    [ {}, { "kit" => nil }, { "kit" => "bootstrap5" } ].each do |config|
      errors = runtime_errors(config)
      assert_equal 1, errors.size, config.inspect
      assert_match(/\Aruntime\/config\.json names no kit/, errors.first, config.inspect)
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

  # Ruling R23: Tailwind is MIT-licensed, so its licence travels with the build.
  test "the Tailwind kit ships Tailwind's licence beside the build, and the plain kit none" do
    @project.design_base_kit = "tailwind4"
    Designs::Template.render_into(@dir, project: @project)
    assert_includes File.read(File.join(@dir, "runtime/kit-license.txt")), "MIT"

    Dir.mktmpdir("template-plain") do |dir|
      @project.design_base_kit = "plain"
      Designs::Template.render_into(dir, project: @project)
      assert_not File.exist?(File.join(dir, "runtime/kit-license.txt"))
    end
  end

  # The browser build puts Tailwind itself in front of the theme only when the
  # theme never spells out the import rule, in a comment or anywhere else: one
  # mention, and every utility is gone.
  test "the Tailwind theme never spells out the import rule" do
    @project.design_base_kit = "tailwind4"
    Designs::Template.render_into(@dir, project: @project)
    assert_not_includes File.read(File.join(@dir, "design_system/theme.css")), "@import"
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

  private

  # Just enough of a browser for runtime/flosis.js to run to the end: a page
  # served from http://preview.test, a fetch that answers with the files below
  # (and 404 for anything else), and elements that load at once. Prints the
  # text of each page-wide error box the runtime put up, as JSON.
  RUNTIME_PAGE = <<~'JS'.freeze
    const fs = require("fs");
    const vm = require("vm");
    const [runtime, config] = process.argv.slice(2);
    const files = {
      "/runtime/config.json": config,
      "/design_system/theme.css": ":root {}",
      "/designs/contexts.json": '{"dimensions": []}',
    };
    const errors = [];
    const element = (tag) => ({ tag, textContent: "", setAttribute() {}, append() {} });
    globalThis.window = globalThis;
    globalThis.location = { protocol: "http:", search: "", origin: "http://preview.test" };
    globalThis.Event = class { constructor(type) { this.type = type; } };
    globalThis.document = {
      currentScript: { src: "http://preview.test/runtime/flosis.js" },
      readyState: "complete",
      baseURI: "http://preview.test/index.html",
      head: { append(child) { if (child.onload) setTimeout(child.onload); } },
      body: { prepend(box) { errors.push(box.textContent); } },
      documentElement: { setAttribute() {} },
      createElement: element,
      querySelectorAll: () => [],
      addEventListener() {},
      dispatchEvent() {},
    };
    globalThis.fetch = async (url) => {
      const body = files[new URL(url).pathname];
      return body === undefined
        ? { ok: false, status: 404, statusText: "Not Found", text: async () => "" }
        : { ok: true, status: 200, statusText: "OK", text: async () => body };
    };
    console.error = () => {};
    vm.runInThisContext(fs.readFileSync(runtime, "utf8"), { filename: runtime });
    window.Flosis.ready.then(() => setTimeout(() => console.log(JSON.stringify(errors))));
  JS

  def runtime_errors(config)
    Dir.mktmpdir("flosis-runtime") do |dir|
      page = File.join(dir, "page.js")
      File.write(page, RUNTIME_PAGE)
      out, err, status = Open3.capture3("node", page, Designs::Template::SOURCE.join("runtime/flosis.js").to_s, config.to_json)
      assert status.success?, err
      JSON.parse(out)
    end
  end
end
