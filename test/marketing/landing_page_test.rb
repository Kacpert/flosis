require "test_helper"

# The marketing landing page is a static file dropped in from design, replaced
# wholesale whenever a new version lands. Every drop-in is a chance for the
# "Sign in" link to come back as a `#pricing` placeholder, which would silently
# strand the only route from flosis.com into the app. Guard it here.
class LandingPageTest < ActiveSupport::TestCase
  SIGN_IN_URL = "https://app.flosis.com/session/new".freeze

  setup do
    @path = Rails.root.join("marketing/index.html")
    @html = File.read(@path)
  end

  test "landing page exists" do
    assert File.exist?(@path), "expected a landing page at marketing/index.html"
  end

  test "every Sign in link points at the app's sign-in page" do
    links = @html.scan(/<a\b([^>]*)>\s*Sign in\s*<\/a>/i).flatten
    assert links.any?, "expected at least one 'Sign in' link in the landing page"

    links.each do |attrs|
      href = attrs[/href\s*=\s*"([^"]*)"/i, 1]
      assert_equal SIGN_IN_URL, href,
        "a 'Sign in' link points at #{href.inspect} instead of #{SIGN_IN_URL}"
    end
  end

  test "landing page does not link back into the app on a bare fragment" do
    refute_match(/<a\b[^>]*href\s*=\s*"#[^"]*"[^>]*>\s*Sign in\s*<\/a>/i, @html,
      "a 'Sign in' link is still an in-page anchor placeholder")
  end
end
