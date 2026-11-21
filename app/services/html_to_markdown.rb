require "nokogiri"

# A description the rich-text editor saved as HTML, as Markdown (2026-11-21):
# Jira (through MarkdownToAdf) and a task's file for the developer get its
# headings, bold, lists and links instead of text whose tags were stripped,
# links' addresses and all.
#
# The editor writes each list line as its own paragraph ("<p>- Admin creates
# a plan.</p>"), so consecutive dash paragraphs join into one list.
module HtmlToMarkdown
  module_function

  HEADINGS = %w[h1 h2 h3 h4 h5 h6].freeze
  # Never text: what they hold must not reach Jira or a file (the strip this
  # replaced dropped them too).
  SKIPPED = %w[script style noscript template iframe object head title].freeze
  BLOCKS = %w[p div section article header footer].freeze
  LIST_LINE = /\A\s*-\s/

  def call(html)
    return "" if html.blank?

    fragment = Nokogiri::HTML5.fragment(html.to_s)
    blocks = fragment.children.flat_map { |node| blocks_of(node) }
    join(blocks.map { |block| tidy(block) }.reject(&:empty?))
  end

  # The Markdown blocks a node makes, as strings.
  def blocks_of(node)
    return [ inline(node) ] if node.text?
    return [] unless node.element?

    name = node.name.downcase
    return [] if SKIPPED.include?(name)

    if HEADINGS.include?(name)
      [ "#{'#' * name[1].to_i} #{inline_children(node).strip}" ]
    elsif BLOCKS.include?(name)
      nested = node.element_children.select { |child| block?(child) }
      nested.any? ? node.children.flat_map { |child| blocks_of(child) } : [ inline_children(node) ]
    elsif name == "ul" || name == "ol"
      [ list(node) ]
    elsif name == "pre"
      [ "```\n#{node.text.chomp}\n```" ]
    elsif name == "blockquote"
      inner = join(node.children.flat_map { |child| blocks_of(child) }.map { |block| tidy(block) }.reject(&:empty?))
      [ inner.lines.map { |line| "> #{line.chomp}" }.join("\n") ]
    elsif name == "hr"
      [ "---" ]
    elsif name == "table"
      [ table(node) ]
    else
      [ inline(node) ]
    end
  end

  def block?(node)
    node.element? && (HEADINGS + BLOCKS + %w[ul ol pre blockquote hr table]).include?(node.name.downcase)
  end

  def list(node, depth = 0)
    ordered = node.name.downcase == "ol"
    node.element_children.select { |child| child.name.downcase == "li" }.each_with_index.map do |item, index|
      marker = ordered ? "#{index + 1}." : "-"
      text = item.children.reject { |child| child.element? && %w[ul ol].include?(child.name.downcase) }
                 .map { |child| inline(child) }.join.strip
      nested = item.element_children.select { |child| %w[ul ol].include?(child.name.downcase) }
                   .map { |sub| list(sub, depth + 1) }
      [ "#{'  ' * depth}#{marker} #{text}", *nested ].join("\n")
    end.join("\n")
  end

  def table(node)
    rows = node.css("tr").map { |row| row.css("th, td").map { |cell| inline_children(cell).strip.gsub("|", "\\|") } }
    return "" if rows.empty?

    lines = rows.map { |cells| "| #{cells.join(' | ')} |" }
    lines.insert(1, "| #{Array.new(rows.first.size, '---').join(' | ')} |")
    lines.join("\n")
  end

  def inline_children(node)
    node.children.map { |child| inline(child) }.join
  end

  def inline(node)
    return node.text.tr(" ", " ").gsub(/[ \t\r\n]+/, " ") if node.text?
    return "" unless node.element?

    case node.name.downcase
    when *SKIPPED then ""
    when "br" then "\n"
    when "b", "strong" then wrap(inline_children(node), "**")
    when "i", "em" then wrap(inline_children(node), "_")
    when "code" then "`#{node.text}`"
    when "a"
      text = inline_children(node)
      href = node["href"].to_s.strip
      href.empty? || text.strip.empty? ? text : "[#{text.strip}](#{href})"
    else inline_children(node)
    end
  end

  # Markers hug the words: "**Plans** " rather than "**Plans **", which
  # Markdown would not render as bold.
  def wrap(text, marker)
    core = text.strip
    return text if core.empty?

    "#{text[/\A\s*/]}#{marker}#{core}#{marker}#{text[/\s*\z/]}"
  end

  def tidy(block)
    block.lines.map(&:rstrip).join("\n").strip
  end

  # Blank lines between blocks; a single newline between list lines.
  def join(blocks)
    blocks.each_with_index.reduce(+"") do |out, (block, index)|
      next out << block if index.zero?

      previous = blocks[index - 1].lines.last.to_s
      out << (LIST_LINE.match?(previous) && LIST_LINE.match?(block) ? "\n" : "\n\n") << block
    end
  end
end
