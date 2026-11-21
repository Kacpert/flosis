require "test_helper"

# The page a task's lasting link opens (2026-11-21): what the thread changed,
# per context, each screen linking to itself and to its changes.
class Designs::ChangesPageTest < ActiveSupport::TestCase
  SCREENS = {
    "contexts" => [ { "id" => "admin", "name" => "Admin" }, { "id" => "flosis-admin", "name" => "Flosis admin" } ],
    "screens" => [
      { "id" => "consumption", "context" => "admin", "name" => "Consumption <this month>" },
      { "id" => "bugs", "context" => "admin", "name" => "Bug Reporting" },
      { "id" => "plans", "context" => "flosis-admin", "name" => "Plans" }
    ]
  }.freeze

  def render(through: {})
    Designs::ChangesPage.render(
      title: "SCRUM-70 · Tokens", status: "In progress",
      own: [ [ "admin", "consumption", "new" ], [ "admin", "bugs", "updated" ], [ "flosis-admin", "plans", "new" ] ],
      through: through, screens: SCREENS
    )
  end

  test "new and updated screens, per context, each with its page and its changes" do
    doc = Nokogiri::HTML5(render)

    assert_equal "SCRUM-70 · Tokens", doc.at("h1").text
    assert_includes doc.text, "In progress"
    assert_equal [ "Admin", "Flosis admin" ], doc.css("h2").map(&:text)
    admin = doc.css("section")[0]
    assert_equal [ "New", "Updated" ], admin.css("h3").map(&:text)
    assert_equal "../designs/admin/consumption.html", admin.at("a:contains('Consumption')")["href"]
    assert_equal [ "../designs/admin/consumption.changes.html", "../designs/admin/bugs.changes.html" ],
                 admin.css("a.changes").map { |link| link["href"] }
    assert_nil doc.at("script")
  end

  test "names are escaped" do
    assert_includes render, "Consumption &lt;this month&gt;"
  end

  test "the line about shared components shows only when one reached other screens" do
    assert_not_includes render, "Through shared components"
    page = Nokogiri::HTML5(render(through: { "sidebar" => [ [ "admin", "bugs" ] ], "chat-panel" => [ [ "admin", "x" ] ] }))
    assert_includes page.text, "Through shared components: sidebar, chat panel"
  end
end
