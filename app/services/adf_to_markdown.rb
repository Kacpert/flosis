# Atlassian Document Format -> Markdown.
#
# Replaces the flattening that JiraClient#adf_to_text did for descriptions: it
# dropped every heading, bold and link, and — worst — ran a table's cells
# together into one unreadable line ("FilterWhat it doesExampleTags..."). A
# description that reads beautifully in Jira arrived here as a wall of text.
#
# Markdown (not HTML) is the target because that is the format the rest of the
# Workshop speaks: briefs are Markdown, the chat renders Markdown, and
# MarkdownToAdf converts it back when we write a ticket to Jira — so a
# description now survives a full round trip.
#
# Anything unknown degrades to its text content rather than raising: a ticket
# must never fail to sync because of an exotic node.
class AdfToMarkdown
  # Marks that wrap inline text, innermost first (the order they are applied).
  MARK_WRAPPERS = {
    "code" => "`",
    "strong" => "**",
    "em" => "*", # the app's renderer (lib/clar_markdown.js) only reads * for italics
    "strike" => "~~"
  }.freeze

  def self.call(node)
    new.convert(node)
  end

  def convert(node)
    node = JSON.parse(node) if node.is_a?(String) && node.present?
    return nil if node.nil?

    blocks(node["content"]).join("\n\n").strip.presence
  rescue JSON::ParserError
    nil
  end

  private

  def blocks(content)
    Array(content).filter_map { |child| block(child).presence }
  end

  def block(node, depth: 0)
    case node["type"]
    when "paragraph"      then inline(node["content"])
    when "heading"        then heading(node)
    when "bulletList"     then list(node, depth: depth, ordered: false)
    when "orderedList"    then list(node, depth: depth, ordered: true)
    when "codeBlock"      then code_block(node)
    when "blockquote"     then prefix_lines(blocks(node["content"]).join("\n\n"), "> ")
    when "rule"           then "---"
    when "table"          then table(node)
    when "panel"          then panel(node)
    when "mediaSingle", "mediaGroup", "mediaInline", "media" then media(node)
    else
      # Unknown block: keep whatever text it carries rather than dropping it.
      node.key?("content") ? blocks(node["content"]).join("\n\n") : inline([ node ])
    end
  end

  def heading(node)
    level = (node.dig("attrs", "level") || 2).to_i.clamp(1, 6)
    text = inline(node["content"])
    text.present? ? "#{'#' * level} #{text}" : ""
  end

  def code_block(node)
    language = node.dig("attrs", "language").to_s
    body = Array(node["content"]).map { |child| child["text"] }.join
    "```#{language}\n#{body}\n```"
  end

  # Nested lists indent by two spaces per level, which is what every Markdown
  # renderer (including the app's own) reads back as nesting.
  def list(node, depth:, ordered:)
    Array(node["content"]).each_with_index.map do |item, index|
      marker = ordered ? "#{index + 1}." : "-"
      item_blocks = Array(item["content"])

      # The first paragraph sits on the bullet line; anything after it (a nested
      # list, a second paragraph) goes underneath, indented.
      head, *rest = item_blocks
      lines = [ "#{'  ' * depth}#{marker} #{block(head.to_h, depth: depth + 1)}".rstrip ]
      rest.each do |child|
        nested = block(child, depth: depth + 1)
        next if nested.blank?
        lines << (child["type"].to_s.end_with?("List") ? nested : prefix_lines(nested, "  " * (depth + 1)))
      end
      lines.join("\n")
    end.join("\n")
  end

  # A GFM pipe table. Jira tables have no separate header row type — the first
  # row's cells are tableHeader when the author marked it as a header — so we
  # use the first row as the header either way (GFM has no headerless table)
  # and keep every cell on one line, since a pipe table cannot hold newlines.
  def table(node)
    rows = Array(node["content"]).select { |r| r["type"] == "tableRow" }
    return "" if rows.empty?

    cells = rows.map { |row| Array(row["content"]).map { |cell| table_cell(cell) } }
    width = cells.map(&:size).max

    header, *body = cells
    header = pad(header, width)

    lines = [ "| #{header.join(' | ')} |", "| #{Array.new(width, '---').join(' | ')} |" ]
    body.each { |row| lines << "| #{pad(row, width).join(' | ')} |" }
    lines.join("\n")
  end

  def table_cell(cell)
    text = blocks(cell["content"]).join(" ")
    # A literal pipe would break the row; newlines collapse to <br> so a
    # multi-paragraph cell still reads as one cell.
    text.gsub("|", "\\|").gsub(/\s*\n+\s*/, "<br>").strip
  end

  def pad(row, width)
    row + Array.new([ width - row.size, 0 ].max, "")
  end

  # Jira "info"/"warning"/"note" panels: a blockquote keeps them visually set
  # apart without inventing syntax the renderer doesn't know.
  def panel(node)
    prefix_lines(blocks(node["content"]).join("\n\n"), "> ")
  end

  def media(node)
    alt = node.dig("attrs", "alt").presence || node.dig("attrs", "id").to_s
    url = node.dig("attrs", "url")
    return "![#{alt}](#{url})" if url.present?

    # An attachment reference (id only) has no URL here — name it so the reader
    # knows something is attached rather than seeing a silent gap.
    node.key?("content") ? blocks(node["content"]).join("\n\n") : "_[attachment: #{alt}]_"
  end

  def inline(content)
    Array(content).map { |node| inline_node(node) }.join
  end

  def inline_node(node)
    case node["type"]
    when "text"       then marked_text(node)
    when "hardBreak"  then "  \n"
    when "emoji"      then node.dig("attrs", "text").presence || node.dig("attrs", "shortName").to_s
    when "mention"    then mention(node)
    when "inlineCard", "embedCard", "blockCard" then node.dig("attrs", "url").to_s
    when "date"       then node.dig("attrs", "timestamp").to_s
    else
      node.key?("content") ? inline(node["content"]) : node["text"].to_s
    end
  end

  def mention(node)
    text = node.dig("attrs", "text").to_s
    text.start_with?("@") ? text : "@#{text}"
  end

  # Applies the node's marks to its text. A link wraps last so its label keeps
  # any bold/italic inside it.
  def marked_text(node)
    text = node["text"].to_s
    return text if text.empty?

    marks = Array(node["marks"])
    MARK_WRAPPERS.each do |type, wrapper|
      next unless marks.any? { |m| m["type"] == type }
      # Don't wrap padding whitespace — "** bold **" is not bold in Markdown.
      text = text.sub(/\A(\s*)(.*?)(\s*)\z/m) { "#{$1}#{wrapper}#{$2}#{wrapper}#{$3}" }
    end

    link = marks.find { |m| m["type"] == "link" }
    href = link&.dig("attrs", "href")
    href.present? ? "[#{text}](#{href})" : text
  end

  def prefix_lines(text, prefix)
    text.to_s.lines.map { |line| "#{prefix}#{line.chomp}".rstrip }.join("\n")
  end
end
