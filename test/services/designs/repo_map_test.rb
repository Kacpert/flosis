require "test_helper"

class Designs::RepoMapTest < ActiveSupport::TestCase
  setup do
    @dirs = []
  end

  teardown do
    @dirs.each { |dir| FileUtils.remove_entry(dir) }
  end

  def repo(files)
    dir = Pathname(Dir.mktmpdir("map")).tap { |made| @dirs << made }
    files.each do |path, body|
      dir.join(path).dirname.mkpath
      dir.join(path).binwrite(body)
    end
    dir
  end

  test "it gives the kit, each screen by its title and each component by the first line of its guidelines" do
    root = repo("runtime/config.json" => '{"kit": "tailwind4"}',
                "designs/admin/reporting.html" => "<html><head><title>Reporting &amp; usage</title></head></html>",
                "designs/admin/no-title.html" => "<p>x</p>",
                "designs/candidate/apply.html" => "<title>Application form</title>",
                "components/metric-tile/metric-tile.html" => "<div></div>",
                "components/metric-tile/README.md" => "# Metric tile\n\nA single number with its label.\n\nMore.",
                "components/switch/switch.html" => "<input>",
                "design-system/theme.css" => "@theme { --color-primary: #1779ba; }")

    text = Designs::RepoMap.text(root)

    assert_includes text, "Kit: tailwind4"
    assert_includes text, "- designs/admin/no-title.html — No-title\n- designs/admin/reporting.html — Reporting & usage\n" \
                          "- designs/candidate/apply.html — Application form"
    assert_includes text, "- components/metric-tile/ — A single number with its label.\n- components/switch/"
    assert_not_includes text, "--color-primary", "the theme comes whole on a session's first turn only"
  end

  test "on a session's first turn it gives the theme and the open screen whole, and leaves a file too big for Claude to read" do
    root = repo("designs/admin/reporting.html" => "<title>Reporting</title><main>Usage</main>",
                "designs/admin/huge.html" => "<title>Huge</title>#{'x' * (Designs::RepoMap::SCREEN_LIMIT + 1)}",
                "design-system/theme.css" => "@theme { --color-primary: #1779ba; }")

    text = Designs::RepoMap.text(root, focus: "designs/admin/reporting.html", full: true)

    assert_includes text, "### design-system/theme.css\n```css\n@theme { --color-primary: #1779ba; }\n```"
    assert_includes text, "### The screen the person has open: designs/admin/reporting.html\n```html\n<title>Reporting</title><main>Usage</main>\n```"
    huge = Designs::RepoMap.text(root, focus: "designs/admin/huge.html", full: true)
    assert_includes huge, "### The screen the person has open: designs/admin/huge.html\n(too big to give here: read it yourself)"
    assert_not_includes huge, "xxxxxxxxxx"
  end

  test "an empty repo says so" do
    text = Designs::RepoMap.text(repo({}), focus: "designs/admin/reporting.html", full: true)

    assert_includes text, "Kit: unknown"
    assert_includes text, "### Screens\n(none yet)"
    assert_includes text, "### Components\n(none yet)"
    assert_not_includes text, "open:"
  end

  # The map goes to Claude: a link must never carry a file from outside the
  # design repo into it.
  test "a link that leads out of the repo is never followed" do
    outside = repo("secret.html" => "<title>Secret</title>SECRET", "theme.css" => "SECRET-THEME", "README.md" => "SECRET-README")
    root = repo("designs/admin/real.html" => "<title>Real</title>")
    File.symlink(outside.join("secret.html"), root.join("designs/admin/link.html"))
    File.symlink(outside, root.join("designs/elsewhere"))
    root.join("components/evil").mkpath
    File.symlink(outside.join("README.md"), root.join("components/evil/README.md"))
    root.join("design-system").mkpath
    File.symlink(outside.join("theme.css"), root.join("design-system/theme.css"))

    text = Designs::RepoMap.text(root, focus: "designs/admin/link.html", full: true)

    assert_includes text, "- designs/admin/real.html — Real"
    assert_no_match(/Secret|SECRET|link\.html|elsewhere/, text)
  end

  # The map comes before every turn of every thread: a file it cannot read as
  # it expects must not fail them all.
  test "a file that is not text it can read, or not a file at all, never stops the map" do
    root = repo("runtime/config.json" => "[1, 2]",
                "designs/admin/real.html" => "<title>Real</title>",
                "components/latin/README.md" => "# Tile\n\nZa\xB3\xF3\xBF g\xEAsi\xB1 ja\xBC\xF1\n".b,
                "components/latin/latin.html" => "<div></div>")
    root.join("designs/admin/folder.html").mkpath

    text = Designs::RepoMap.text(root)

    assert_includes text, "Kit: unknown"
    assert_includes text, "- designs/admin/real.html — Real"
    assert_includes text, "- components/latin/"
    assert_not_includes text, "folder.html"
  end
end
