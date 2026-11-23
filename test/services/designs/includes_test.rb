require "test_helper"

class Designs::IncludesTest < ActiveSupport::TestCase
  def expand(html, files)
    Designs::Includes.expand(html, reader: ->(path) { files[path] })
  end

  def body(html)
    Nokogiri::HTML5(html).at("body").inner_html.strip
  end

  test "a component takes the include's place, its placeholders filled from the include's attributes" do
    html = expand('<body><x-include src="components/button.html" label="Save &amp; go"></x-include></body>',
                  "components/button.html" => "<button>{{ label }}</button>")

    assert_equal "<button>Save &amp; go</button>", body(html)
  end

  test "the include's children take the component's slot" do
    html = expand('<body><x-include src="components/card.html"><p>Inside</p></x-include></body>',
                  "components/card.html" => '<div class="card"><slot></slot></div>')

    assert_equal '<div class="card"><p>Inside</p></div>', body(html)
  end

  # Kacper, 2026-11-23: the Changes view of task 551's Consumption showed its
  # four period rows and both banners at once. The runtime puts an include's
  # state attributes on each element of its component; this expansion, which
  # the Changes view is made from, must do the same.
  test "an include's states go onto each element of its component, as the runtime puts them" do
    html = expand('<body><x-include src="components/row.html" data-show-in="over-limit" data-hide-in="paused" data-open-in="edit">' \
                  "<em>In</em></x-include></body>",
                  "components/row.html" => '<div class="row">A</div> <slot></slot><span>B</span>')
    elements = Nokogiri::HTML5(html).at("body").element_children

    assert_equal %w[div em span], elements.map(&:name)
    elements.each do |element|
      assert_equal "over-limit", element["data-show-in"], element.name
      assert_equal "paused", element["data-hide-in"], element.name
      assert_equal "edit", element["data-open-in"], element.name
    end
  end

  test "a component's elements keep their own states when the include names none" do
    html = expand('<body><x-include src="components/row.html" label="x"></x-include></body>',
                  "components/row.html" => '<div data-show-in="paused">A</div><span>B</span>')
    div, span = Nokogiri::HTML5(html).at("body").element_children.to_a

    assert_equal "paused", div["data-show-in"]
    assert_nil span["data-show-in"]
  end

  test "components may include components" do
    html = expand('<body><x-include src="components/a.html"></x-include></body>',
                  "components/a.html" => '<div><x-include src="components/b.html"></x-include></div>',
                  "components/b.html" => "<span>b</span>")

    assert_equal "<div><span>b</span></div>", body(html)
  end

  test "a cycle stops after ten rounds and leaves a marker" do
    html = expand('<body><x-include src="components/loop.html"></x-include></body>',
                  "components/loop.html" => '<i><x-include src="components/loop.html"></x-include></i>')

    assert_includes html, 'data-flosis-missing="components/loop.html"'
    assert_equal 10, Nokogiri::HTML5(html).css("i").size
  end

  test "a path out of the repo, an absolute one or a missing one is never read" do
    read = []
    reader = ->(path) { read << path; nil }
    html = Designs::Includes.expand(
      '<body><x-include src="../secret"></x-include><x-include src="/etc/passwd"></x-include>' \
      '<x-include src="https://example.com/x.html"></x-include><x-include src="components/../../x.html"></x-include>' \
      '<x-include src="components/missing.html"></x-include><x-include src=""></x-include></body>', reader: reader)

    assert_equal [ "components/missing.html" ], read
    assert_equal 6, Nokogiri::HTML5(html).css("[data-flosis-missing]").size
  end

  test "a missing component shows as the runtime's red box, naming its src" do
    html = expand('<body><x-include src="components/missing.html"></x-include></body>', {})
    box = Nokogiri::HTML5(html).at("[data-flosis-missing]")
    assert_equal "Missing component: components/missing.html", box.text
    assert_includes box["style"], "border:2px solid #c00"
  end

  test "an include that grows past the size cap stops growing" do
    html = expand('<body><x-include src="components/twice.html"></x-include></body>',
                  "components/twice.html" => ("<p>#{'x' * 2_000}</p>" + '<x-include src="components/twice.html"></x-include>' * 2))
    assert_operator html.bytesize, :<, Designs::Includes::MAX_BYTES * 3
    assert_includes html, "Components too large to show"
  end

end
