# <x-include> expanded on the server, the way the design repo's runtime
# (runtime/flosis.js) expands it in the browser, so that Changes compares what
# people see: {{ name }} takes the include's attribute, escaped; the include's
# children take the component's <slot>; components may include components, up
# to ten rounds. It is text all the way: nothing in a design repo runs here.
#
# A src is a path from the repo's root. One that is empty, absolute, has a
# scheme or climbs out of the repo is never read, and neither is one the reader
# cannot find: each leaves <div data-flosis-missing="<src>"> in its place, as
# does an include still there after the tenth round (a cycle).
module Designs::Includes
  MAX_ROUNDS = 10
  # No screen's markup grows past this, however its components nest: a
  # component that includes itself twice would otherwise double each round.
  MAX_BYTES = 2_000_000
  TOO_LARGE = "Components too large to show".freeze
  PLACEHOLDER = /\{\{\s*([\w-]+)\s*\}\}/

  module_function

  # root: what leads from the page to the repo's root ("../../" from a screen),
  # put before every relative src, href and poster a component brings in, as
  # the runtime makes them absolute; nil leaves them as written.
  def expand(html, reader:, root: nil)
    document = Nokogiri::HTML5(html.to_s)
    cache = {}
    MAX_ROUNDS.times do
      includes = document.css("x-include[src]")
      break if includes.empty? || document.to_html.bytesize > MAX_BYTES

      includes.each { |element| include!(element, reader, cache, root) }
    end
    if document.to_html.bytesize > MAX_BYTES
      document.css("x-include[src]").each { |element| element.replace(marker(document, element["src"], TOO_LARGE)) }
    end
    document.css("x-include[src]").each { |element| element.replace(marker(document, element["src"])) }
    document.to_html
  end

  # The repo path a src names, or nil when it must not be read.
  def path_for(src)
    value = src.to_s.strip
    return if value.empty? || value.start_with?("/") || value.include?("\\") || value.match?(/\A[a-z][a-z\d+.-]*:/i)

    path = Pathname.new(value).cleanpath.to_s
    path unless path == "." || path == ".." || path.start_with?("../")
  end

  def include!(element, reader, cache, root)
    path = path_for(element["src"])
    text = path && cache.fetch(path) { cache[path] = reader.call(path) }
    return element.replace(marker(element.document, element["src"])) if text.nil?

    fragment = element.document.fragment(text.gsub(PLACEHOLDER) { CGI.escapeHTML(element[$1].to_s) })
    from_root!(fragment, root) if root
    fragment.at_css("slot")&.replace(element.children)
    element.replace(fragment)
  end

  # Left as they are, as in the runtime: URLs with a scheme, //host and /path,
  # and #… or ?…, which point into the page itself.
  def from_root!(fragment, root)
    fragment.css("[src], [href], [poster]").each do |node|
      next if node.name == "x-include"

      %w[src href poster].each do |name|
        value = node[name]
        node[name] = root + value if value.present? && !value.strip.match?(%r{\A([a-z][a-z\d+.-]*:|[/#?])}i)
      end
    end
  end

  # The runtime's own red box (runtime/flosis.js errorBox), so a component
  # that cannot be shown says so in Changes too.
  def marker(document, src, text = "Missing component")
    Nokogiri::XML::Node.new("div", document).tap do |node|
      node["data-flosis-missing"] = src.to_s
      node["style"] = "border:2px solid #c00;padding:8px"
      node.content = "#{text}: #{src}"
    end
  end
end
