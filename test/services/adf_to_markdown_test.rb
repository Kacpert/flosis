require "test_helper"

# A Jira description that reads well in Jira has to read well here too. The old
# adf_to_text flattening dropped headings/bold and ran table cells together
# ("FilterWhat it doesExample…"), which is what these cover.
class AdfToMarkdownTest < ActiveSupport::TestCase
  def doc(*content)
    { "type" => "doc", "version" => 1, "content" => content }
  end

  def text(value, marks: nil)
    node = { "type" => "text", "text" => value }
    node["marks"] = marks if marks
    node
  end

  def paragraph(*content) = { "type" => "paragraph", "content" => content }

  test "returns nil for a blank document" do
    assert_nil AdfToMarkdown.call(nil)
    assert_nil AdfToMarkdown.call(doc)
  end

  test "keeps heading levels" do
    result = AdfToMarkdown.call(doc(
      { "type" => "heading", "attrs" => { "level" => 1 }, "content" => [ text("Why we're doing this") ] },
      { "type" => "heading", "attrs" => { "level" => 3 }, "content" => [ text("Filters") ] }
    ))

    assert_equal "# Why we're doing this\n\n### Filters", result
  end

  test "carries bold, italic, code and strike through" do
    result = AdfToMarkdown.call(doc(paragraph(
      text("Many customers want "),
      text("different job lists", marks: [ { "type" => "strong" } ]),
      text(" on "),
      text("their own site", marks: [ { "type" => "em" } ]),
      text(" via "),
      text("/engineering", marks: [ { "type" => "code" } ])
    )))

    assert_equal "Many customers want **different job lists** on *their own site* via `/engineering`", result
  end

  test "does not wrap the padding whitespace of a mark" do
    # "** bold **" renders literally, not as bold.
    result = AdfToMarkdown.call(doc(paragraph(text(" spaced ", marks: [ { "type" => "strong" } ]))))

    assert_equal "**spaced**", result.strip
    assert_not_includes result, "** "
  end

  test "renders a link, keeping marks inside the label" do
    result = AdfToMarkdown.call(doc(paragraph(
      text("open API", marks: [ { "type" => "strong" }, { "type" => "link", "attrs" => { "href" => "https://ex.com/api" } } ])
    )))

    assert_equal "[**open API**](https://ex.com/api)", result
  end

  test "renders bullet and ordered lists" do
    result = AdfToMarkdown.call(doc(
      { "type" => "orderedList", "content" => [
        { "type" => "listItem", "content" => [ paragraph(text("Choose what jobs appear")) ] },
        { "type" => "listItem", "content" => [ paragraph(text("Preview the list")) ] }
      ] },
      { "type" => "bulletList", "content" => [
        { "type" => "listItem", "content" => [ paragraph(text("Tags")) ] }
      ] }
    ))

    assert_equal "1. Choose what jobs appear\n2. Preview the list\n\n- Tags", result
  end

  test "indents a nested list under its parent item" do
    result = AdfToMarkdown.call(doc(
      { "type" => "bulletList", "content" => [
        { "type" => "listItem", "content" => [
          paragraph(text("Filters")),
          { "type" => "bulletList", "content" => [
            { "type" => "listItem", "content" => [ paragraph(text("Tags")) ] }
          ] }
        ] }
      ] }
    ))

    assert_equal "- Filters\n  - Tags", result
  end

  # The reason this class exists.
  test "renders a table as a GFM pipe table instead of running the cells together" do
    row = ->(cells) do
      { "type" => "tableRow", "content" => cells.map { |c| { "type" => "tableCell", "content" => [ paragraph(text(c)) ] } } }
    end
    header = { "type" => "tableRow", "content" => %w[Filter What\ it\ does Example].map { |c|
      { "type" => "tableHeader", "content" => [ paragraph(text(c)) ] }
    } }

    result = AdfToMarkdown.call(doc(
      { "type" => "table", "content" => [ header, row.call([ "Tags", "Jobs marked with selected tag(s)", "\"Graduate\"" ]) ] }
    ))

    assert_equal <<~MD.strip, result
      | Filter | What it does | Example |
      | --- | --- | --- |
      | Tags | Jobs marked with selected tag(s) | "Graduate" |
    MD
  end

  test "pads a short row and escapes a pipe inside a cell" do
    result = AdfToMarkdown.call(doc({ "type" => "table", "content" => [
      { "type" => "tableRow", "content" => [
        { "type" => "tableHeader", "content" => [ paragraph(text("A")) ] },
        { "type" => "tableHeader", "content" => [ paragraph(text("B")) ] }
      ] },
      { "type" => "tableRow", "content" => [
        { "type" => "tableCell", "content" => [ paragraph(text("public | private")) ] }
      ] }
    ] }))

    assert_includes result, "| public \\| private |  |"
  end

  test "renders a fenced code block with its language" do
    result = AdfToMarkdown.call(doc(
      { "type" => "codeBlock", "attrs" => { "language" => "ruby" }, "content" => [ text("puts :hi") ] }
    ))

    assert_equal "```ruby\nputs :hi\n```", result
  end

  test "renders rules and turns panels into blockquotes" do
    result = AdfToMarkdown.call(doc(
      { "type" => "rule" },
      { "type" => "panel", "attrs" => { "panelType" => "info" }, "content" => [ paragraph(text("Not in v1: saved presets.")) ] }
    ))

    assert_equal "---\n\n> Not in v1: saved presets.", result
  end

  test "keeps the text of an unknown node rather than dropping it" do
    result = AdfToMarkdown.call(doc(
      { "type" => "someFutureThing", "content" => [ paragraph(text("still important")) ] }
    ))

    assert_equal "still important", result
  end

  test "accepts the stored ADF JSON string and survives malformed JSON" do
    json = doc(paragraph(text("From a column"))).to_json

    assert_equal "From a column", AdfToMarkdown.call(json)
    assert_nil AdfToMarkdown.call("{not json")
  end

  test "renders hard breaks as a markdown line break" do
    result = AdfToMarkdown.call(doc(paragraph(text("one"), { "type" => "hardBreak" }, text("two"))))

    assert_equal "one  \ntwo", result
  end
end
