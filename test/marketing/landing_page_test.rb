require "test_helper"

# The marketing pages are static files built from design exports by
# script/build_landing.rb, and replaced wholesale whenever a new version lands.
# Every export so far has re-lost the Sign in links (they come back as
# `#pricing` placeholders), which would strand the only route from flosis.com
# into the app. These tests fail the build rather than let that ship.
class LandingPageTest < ActiveSupport::TestCase
  SIGN_IN_URL = "https://app.flosis.com/session/new".freeze

  LIGHT = "marketing/index.html".freeze   # the default, served at /
  DARK  = "marketing/dark.html".freeze

  def read(page) = File.read(Rails.root.join(page))

  test "both themes are present" do
    [ LIGHT, DARK ].each do |page|
      assert File.exist?(Rails.root.join(page)), "expected a landing page at #{page}"
    end
  end

  test "every Sign in link points at the app's sign-in page" do
    [ LIGHT, DARK ].each do |page|
      links = read(page).scan(/<a\b([^>]*)>\s*Sign in\s*<\/a>/i).flatten
      assert links.any?, "expected at least one 'Sign in' link in #{page}"

      links.each do |attrs|
        href = attrs[/href\s*=\s*"([^"]*)"/i, 1]
        assert_equal SIGN_IN_URL, href,
          "a 'Sign in' link in #{page} points at #{href.inspect} instead of #{SIGN_IN_URL}"
      end
    end
  end

  test "no Sign in link is left as an in-page anchor placeholder" do
    [ LIGHT, DARK ].each do |page|
      refute_match(/<a\b[^>]*href\s*=\s*"#[^"]*"[^>]*>\s*Sign in\s*<\/a>/i, read(page),
        "a 'Sign in' link in #{page} is still an in-page anchor placeholder")
    end
  end

  # The switch is a link between the two files. Design exports point it at the
  # on-disk filename it was authored with ("Flosis Landing.html"), which 404s
  # once deployed.
  test "the theme switch links the two pages to each other" do
    assert_match(/<a\b[^>]*class="themesw"[^>]*href="\/dark\.html"/i, read(LIGHT),
      "the light page's theme switch does not point at /dark.html")
    assert_match(/<a\b[^>]*class="themesw"[^>]*href="\/"/i, read(DARK),
      "the dark page's theme switch does not point back at /")
  end

  # Light is the default. A visitor who previously chose dark has to be sent on
  # before anything paints, otherwise they get a flash of the wrong theme.
  test "the light page redirects visitors who chose dark, before it paints" do
    html = read(LIGHT)
    head = html[/<head>(.*?)<link/mi, 1].to_s

    assert_match(/localStorage\.getItem\('flosisLandingTheme'\)==='dark'/, head,
      "the dark-preference redirect is missing from the light page's <head>")
    assert_match(/location\.replace\('\/dark\.html'\)/, head,
      "the dark-preference redirect does not send visitors to /dark.html")
  end

  test "the dark page does not redirect, so it stays reachable directly" do
    refute_match(/location\.replace/, read(DARK),
      "the dark page redirects, which would trap or bounce visitors")
  end

  # Both pages have to record the choice, or the switch is a one-way trip.
  test "both pages persist the theme choice on switch" do
    [ LIGHT, DARK ].each do |page|
      assert_match(/localStorage\.setItem\('flosisLandingTheme'/, read(page),
        "#{page} does not record the visitor's theme choice")
    end
  end
end
