require "test_helper"

class Designs::ScreensTest < ActiveSupport::TestCase
  FILES = {
    "designs/admin/pipeline.html" => "<html><head><title>Pipeline</title></head><body>p</body></html>",
    "designs/admin/users_and_roles.html" => "<html><body>no title</body></html>",
    "designs/candidate/apply.html" => "<html><head><title>Application form</title></head><body>a</body></html>",
    "designs/candidate/notes.txt" => "not a screen",
    "designs/README.md" => "not a screen either",
    "components/button.html" => "<button>b</button>"
  }.freeze

  def screens(files = FILES)
    Designs::Screens.new(paths: files.keys, reader: ->(path) { files[path] })
  end

  test "contexts are the folders under designs/, named after them" do
    assert_equal [ { id: "admin", name: "Admin" }, { id: "candidate", name: "Candidate" } ], screens.contexts
  end

  test "a screen is an html file in a context folder, named by its title" do
    pipeline = screens.find("admin", "pipeline")

    assert_equal "Pipeline", pipeline[:name]
    assert_equal "designs/admin/pipeline.html", pipeline[:path]
    assert_equal "Users and roles", screens.find("admin", "users_and_roles")[:name]
    assert_nil screens.find("candidate", "notes")
    assert_equal 3, screens.screens.size
  end

  test "the contexts a screen exists in" do
    files = FILES.merge("designs/candidate/pipeline.html" => "<title>Pipeline</title>")

    assert_equal %w[admin candidate], screens(files).contexts_for("pipeline")
  end

  test "names that could not go into a link are left out" do
    files = { "designs/ad min/x.html" => "x", "designs/admin/a b.html" => "x", "designs/admin/ok.html" => "x" }

    assert_equal [ "ok" ], screens(files).screens.map { |s| s[:id] }
  end
end
