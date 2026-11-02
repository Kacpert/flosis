require "test_helper"

class Designs::ChangesTest < ActiveSupport::TestCase
  def screens(files)
    Designs::Screens.new(paths: files.keys, reader: ->(path) { files[path] })
  end

  def changes(base, head)
    Designs::Changes.new(base: screens(base), head: screens(head))
  end

  def marks(html)
    Nokogiri::HTML5(html).css("[data-flosis-change]").map { |node| [ node.name, node["data-flosis-change"], node.text.strip ] }
  end

  PAGE = '<html><head><title>Apply</title></head><body><h1>Apply</h1><form><label>Name</label><button class="btn">Submit</button></form></body></html>'.freeze

  test "an added element is new" do
    head = PAGE.sub("<button", "<p>121 / 500</p><button")
    result = changes({ "designs/candidate/apply.html" => PAGE }, { "designs/candidate/apply.html" => head })

    assert_equal [ { context: "candidate", screen: "apply", kind: "updated" } ], result.changed
    assert_equal [ [ "p", "new", "121 / 500" ] ], marks(result.marked_html("candidate", "apply"))
  end

  test "changed text or attributes mark the element that changed" do
    head = PAGE.sub("Submit", "Submit application").sub('<button class="btn">', '<button class="btn" disabled>')
    result = changes({ "designs/candidate/apply.html" => PAGE }, { "designs/candidate/apply.html" => head })

    assert_equal [ [ "button", "updated", "Submit application" ] ], marks(result.marked_html("candidate", "apply"))
  end

  test "an unchanged screen is not listed, whatever its whitespace" do
    head = PAGE.gsub("><", ">\n  <")
    result = changes({ "designs/candidate/apply.html" => PAGE }, { "designs/candidate/apply.html" => head })

    assert_empty result.changed
    assert_empty marks(result.marked_html("candidate", "apply"))
  end

  test "a screen the base lacks is new as a whole" do
    result = changes({}, { "designs/candidate/apply.html" => PAGE })

    assert_equal [ { context: "candidate", screen: "apply", kind: "new" } ], result.changed
    assert_equal "new", Nokogiri::HTML5(result.marked_html("candidate", "apply")).at("body")["data-flosis-change"]
  end

  test "a component that changed marks every screen that includes it" do
    page = '<html><body><x-include src="components/button.html"></x-include></body></html>'
    base = { "designs/admin/a.html" => page, "designs/admin/b.html" => page, "designs/admin/c.html" => "<html><body>c</body></html>",
             "components/button.html" => "<button>Go</button>" }
    head = base.merge("components/button.html" => "<button>Go now</button>")
    result = changes(base, head)

    assert_equal %w[a b], result.changed.map { |change| change[:screen] }
    assert_equal [ [ "button", "updated", "Go now" ] ], marks(result.marked_html("admin", "a"))
  end

  test "an element removed from a list marks the list" do
    base = '<html><body><ul class="rows"><li>One</li><li>Two</li><li>Three</li></ul></body></html>'
    head = base.sub("<li>Two</li>", "")
    result = changes({ "designs/admin/list.html" => base }, { "designs/admin/list.html" => head })

    assert_equal [ [ "ul", "updated", "OneThree" ] ], marks(result.marked_html("admin", "list"))
  end
end
