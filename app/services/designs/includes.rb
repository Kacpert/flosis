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
  PLACEHOLDER = /\{\{\s*([\w-]+)\s*\}\}/

  module_function

  def expand(html, reader:)
    document = Nokogiri::HTML5(html.to_s)
    cache = {}
    MAX_ROUNDS.times do
      includes = document.css("x-include[src]")
      break if includes.empty?

      includes.each { |element| include!(element, reader, cache) }
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

  def include!(element, reader, cache)
    path = path_for(element["src"])
    text = path && cache.fetch(path) { cache[path] = reader.call(path) }
    return element.replace(marker(element.document, element["src"])) if text.nil?

    fragment = element.document.fragment(text.gsub(PLACEHOLDER) { CGI.escapeHTML(element[$1].to_s) })
    fragment.at_css("slot")&.replace(element.children)
    element.replace(fragment)
  end

  def marker(document, src)
    Nokogiri::XML::Node.new("div", document).tap { |node| node["data-flosis-missing"] = src.to_s }
  end
end
