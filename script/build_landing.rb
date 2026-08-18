#!/usr/bin/env ruby
# Builds marketing/ from the raw design exports.
#
#   ruby script/build_landing.rb ~/Downloads/"Flosis Landing Light.html" \
#                                ~/Downloads/"Flosis Landing.html"
#
# New landing versions arrive from design as standalone HTML files, and each
# export re-loses the same handful of production details (the Sign in links
# have come back as `#pricing` placeholders every time so far). Rather than
# re-apply them by hand and hope, every fix lives here and is re-applied on
# every build. Each one asserts its match count, so a design change that breaks
# an assumption fails the build instead of quietly shipping a broken page.
#
# Theme persistence: light is the default and is served at `/`. The switch is a
# plain link between two files, and the choice is remembered in localStorage.
# The light page carries a pre-paint redirect so a returning visitor who chose
# dark lands on the dark page.
#
# Why a redirect rather than serving both themes from `/` off a cookie: one URL
# would then have two possible bodies, which needs a correct `Vary: Cookie` to
# survive browser caching. Get that wrong on shared hosting and visitors get
# stuck on the wrong theme, which is both worse and much harder to debug than
# one extra navigation.

SIGN_IN_URL = "https://app.flosis.com/session/new".freeze

# Fires before the stylesheet or fonts are requested, so nothing has painted
# yet. Only on the light page: reaching dark.html is always deliberate.
DARK_REDIRECT = <<~HTML.freeze
  <script>try{if(localStorage.getItem('flosisLandingTheme')==='dark')location.replace('/dark.html');}catch(e){}</script>
HTML

def sub!(html, pattern, replacement, expected, what)
  count = html.scan(pattern).size
  unless count == expected
    abort "build_landing: expected #{expected} #{what}, found #{count}. " \
          "The design export probably changed shape — check before shipping."
  end
  html.gsub(pattern, replacement)
end

def build(source, theme_switch_target, insert_redirect:)
  html = File.read(source)

  # Design exports ship these as in-page `#pricing` placeholders.
  html = sub!(html, /(<a\b[^>]*?)href\s*=\s*"[^"]*"([^>]*>\s*Sign in\s*<\/a>)/i,
              "\\1href=\"#{SIGN_IN_URL}\"\\2", 2, "'Sign in' links")

  # Exports link the themes by their on-disk filenames ("Flosis Landing.html").
  html = sub!(html, /(<a\b[^>]*class="themesw"[^>]*?)href\s*=\s*"[^"]*"/i,
              "\\1href=\"#{theme_switch_target}\"", 1, "theme switch link")

  if insert_redirect
    html = sub!(html, /<head>\n/, "<head>\n#{DARK_REDIRECT}", 1, "<head> tags")
  end

  html
end

light_src, dark_src = ARGV
abort "usage: build_landing.rb <light.html> <dark.html>" unless light_src && dark_src

root = File.expand_path("..", __dir__)
File.write("#{root}/marketing/index.html", build(light_src, "/dark.html", insert_redirect: true))
File.write("#{root}/marketing/dark.html",  build(dark_src,  "/",          insert_redirect: false))

puts "built marketing/index.html (light, default) and marketing/dark.html"
