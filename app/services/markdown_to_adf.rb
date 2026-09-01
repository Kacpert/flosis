# Converts the lightweight Markdown our briefs/drafts use into Atlassian Document
# Format (ADF), so Jira Cloud renders bold/bullets/headings/links instead of the
# raw "**...**" / "- ..." text. Deliberately small — it covers what the brief
# prompt actually produces, not the full Markdown spec:
#   - # / ## / ### headings
#   - **bold** and `code` inline
#   - "- " / "* " bullet lists
#   - GFM pipe tables
#   - --- horizontal rules
#   - bare URLs and [text](url) links
#   - blank-line-separated paragraphs
# Anything else is emitted as plain paragraph text (safe fallback).
#
# Tables and rules landed with AdfToMarkdown: a description pulled FROM Jira
# keeps its tables, so pushing it back had to keep them too — otherwise a
# round trip turned a table into literal "| Filter | What it does |" lines.
class MarkdownToAdf
  URL = %r{https?://[^\s<>()\]]+}
  MD_LINK = /\[([^\]]+)\]\((#{URL})\)/
  BOLD = /\*\*(.+?)\*\*/
  CODE = /`([^`]+)`/
  # A table row is any line fenced by pipes; the divider is the |---|---| line
  # under the header that makes it a table rather than prose with pipes in it.
  TABLE_ROW = /\A\s*\|.*\|\s*\z/
  TABLE_DIVIDER = /\A\s*\|(\s*:?-{3,}:?\s*\|)+\s*\z/
  RULE = /\A\s*(-{3,}|\*{3,}|_{3,})\s*\z/

  def self.call(markdown)
    new(markdown).to_doc
  end

  def initialize(markdown)
    @lines = markdown.to_s.gsub("\r\n", "\n").split("\n")
  end

  # Returns an ADF "doc". Empty input yields a single empty paragraph so Jira
  # always gets a valid document.
  def to_doc
    content = build_blocks
    content = [ { type: "paragraph", content: [] } ] if content.empty?
    { type: "doc", version: 1, content: content }
  end

  private

  def build_blocks
    blocks = []
    i = 0
    while i < @lines.length
      line = @lines[i]

      if line.strip.empty?
        i += 1
        next
      end

      if line.match?(TABLE_ROW) && @lines[i + 1].to_s.match?(TABLE_DIVIDER)
        rows = [ split_row(line) ]
        i += 2 # skip the header and its divider
        while i < @lines.length && @lines[i].match?(TABLE_ROW)
          rows << split_row(@lines[i])
          i += 1
        end
        blocks << table(rows)
      elsif line.match?(RULE)
        blocks << { type: "rule" }
        i += 1
      elsif (m = line.match(/\A(\#{1,6})\s+(.*)\z/)) # heading
        level = m[1].length.clamp(1, 6)
        blocks << heading(level, m[2])
        i += 1
      elsif line.match?(/\A\s*[-*]\s+/) # bullet list — consume the whole run
        items = []
        while i < @lines.length && @lines[i].match?(/\A\s*[-*]\s+/)
          items << list_item(@lines[i].sub(/\A\s*[-*]\s+/, ""))
          i += 1
        end
        blocks << { type: "bulletList", content: items }
      else # paragraph — consume until a blank line or a block starter
        para = []
        while i < @lines.length &&
              !@lines[i].strip.empty? &&
              !@lines[i].match?(/\A\#{1,6}\s+/) &&
              !@lines[i].match?(/\A\s*[-*]\s+/) &&
              !@lines[i].match?(RULE) &&
              !(@lines[i].match?(TABLE_ROW) && @lines[i + 1].to_s.match?(TABLE_DIVIDER))
          para << @lines[i]
          i += 1
        end
        blocks << { type: "paragraph", content: inline(para.join(" ")) }
      end
    end
    blocks
  end

  # ADF tables need every row padded to the same width, and Jira renders the
  # first row as the header (tableHeader cells) — which is exactly what a GFM
  # table means by the row above the divider.
  def table(rows)
    width = rows.map(&:size).max
    header, *body = rows

    content = [ table_row(header, width, "tableHeader") ]
    body.each { |row| content << table_row(row, width, "tableCell") }

    { type: "table", attrs: { isNumberColumnEnabled: false, layout: "default" }, content: content }
  end

  def table_row(cells, width, cell_type)
    padded = cells + Array.new([ width - cells.size, 0 ].max, "")
    {
      type: "tableRow",
      content: padded.map do |cell|
        { type: cell_type, attrs: {}, content: [ { type: "paragraph", content: inline(cell) } ] }
      end
    }
  end

  # "| a | b |" -> ["a", "b"], honouring the \| escape for a literal pipe.
  def split_row(line)
    line.strip
        .sub(/\A\|/, "").sub(/\|\z/, "")
        .split(/(?<!\\)\|/)
        .map { |cell| cell.gsub("\\|", "|").strip }
  end

  def heading(level, text)
    { type: "heading", attrs: { level: level }, content: inline(text) }
  end

  def list_item(text)
    { type: "listItem", content: [ { type: "paragraph", content: inline(text) } ] }
  end

  # Turns a line of text into ADF inline nodes, handling links, bold and code.
  # Links are resolved first (so a URL inside isn't re-split), then the remaining
  # text is scanned for bold/code.
  def inline(text)
    nodes = []
    tokenize_links(text.to_s).each do |token|
      if token.is_a?(Hash) # already a link node
        nodes << token
      else
        nodes.concat(marks_for(token))
      end
    end
    nodes.empty? ? [ { type: "text", text: "" } ] : nodes
  end

  # Splits text into a list of plain strings and link nodes.
  def tokenize_links(text)
    out = []
    rest = text
    until rest.empty?
      md = rest.match(MD_LINK)
      bare = rest.match(URL)
      # Pick whichever link form appears first.
      match, href, label =
        if md && (!bare || md.begin(0) <= bare.begin(0))
          [ md, md[2], md[1] ]
        elsif bare
          [ bare, bare[0], bare[0] ]
        end

      break unless match

      out << rest[0...match.begin(0)] if match.begin(0) > 0
      out << link_node(label, href)
      rest = rest[match.end(0)..] || ""
    end
    out << rest unless rest.empty?
    out
  end

  def link_node(text, href)
    { type: "text", text: text, marks: [ { type: "link", attrs: { href: href } } ] }
  end

  # Applies bold/code marks within a plain string, emitting text nodes.
  def marks_for(str)
    nodes = []
    rest = str
    until rest.empty?
      b = rest.match(BOLD)
      c = rest.match(CODE)
      match, mark, inner =
        if b && (!c || b.begin(0) <= c.begin(0))
          [ b, "strong", b[1] ]
        elsif c
          [ c, "code", c[1] ]
        end

      unless match
        nodes << { type: "text", text: rest } unless rest.empty?
        break
      end

      nodes << { type: "text", text: rest[0...match.begin(0)] } if match.begin(0) > 0
      nodes << { type: "text", text: inner, marks: [ { type: mark } ] }
      rest = rest[match.end(0)..] || ""
    end
    nodes
  end
end
