require "test_helper"

class MarkdownToAdfTest < ActiveSupport::TestCase
  def doc(md) = MarkdownToAdf.call(md)

  test "wraps output in a valid ADF doc" do
    d = doc("hello")
    assert_equal "doc", d[:type]
    assert_equal 1, d[:version]
    assert d[:content].is_a?(Array)
  end

  test "empty input still yields a valid doc with an empty paragraph" do
    d = doc("")
    assert_equal [ { type: "paragraph", content: [] } ], d[:content]
  end

  test "bold becomes a strong mark, not literal asterisks" do
    d = doc("**Problem:** something")
    para = d[:content].first
    strong = para[:content].find { |n| n[:marks]&.any? { |m| m[:type] == "strong" } }
    assert_equal "Problem:", strong[:text]
    # no literal ** survives
    refute d[:content].to_json.include?("**")
  end

  test "headings become heading nodes with the right level" do
    d = doc("## Acceptance")
    h = d[:content].first
    assert_equal "heading", h[:type]
    assert_equal 2, h[:attrs][:level]
    assert_equal "Acceptance", h[:content].first[:text]
  end

  test "dash bullets become a bulletList of listItems" do
    d = doc("- one\n- two")
    list = d[:content].first
    assert_equal "bulletList", list[:type]
    assert_equal 2, list[:content].size
    assert_equal "listItem", list[:content].first[:type]
    assert_equal "one", list[:content].first[:content].first[:content].first[:text]
  end

  test "bare URL becomes a link mark" do
    d = doc("See https://www.loom.com/share/abc?sid=1 now")
    link = d[:content].first[:content].find { |n| n[:marks]&.any? { |m| m[:type] == "link" } }
    assert_equal "https://www.loom.com/share/abc?sid=1", link[:text]
    assert_equal "https://www.loom.com/share/abc?sid=1", link[:marks].first[:attrs][:href]
  end

  test "markdown [text](url) link keeps the label and href" do
    d = doc("Open [the doc](https://x.com/y).")
    link = d[:content].first[:content].find { |n| n[:marks]&.any? { |m| m[:type] == "link" } }
    assert_equal "the doc", link[:text]
    assert_equal "https://x.com/y", link[:marks].first[:attrs][:href]
  end

  test "inline code becomes a code mark" do
    d = doc("call `foo` here")
    code = d[:content].first[:content].find { |n| n[:marks]&.any? { |m| m[:type] == "code" } }
    assert_equal "foo", code[:text]
  end

  test "blank lines split paragraphs" do
    d = doc("first para\n\nsecond para")
    paras = d[:content].select { |b| b[:type] == "paragraph" }
    assert_equal 2, paras.size
  end

  # AdfToMarkdown pulls a ticket's tables in; without these the push back turned
  # them into literal "| Filter | What it does |" paragraph lines in Jira.

  test "a pipe table becomes an ADF table with a header row" do
    d = doc(<<~MD)
      | Filter | What it does |
      | --- | --- |
      | Tags | Matches any tag |
      | Dates | Within a range |
    MD

    table = d[:content].first
    assert_equal "table", table[:type]
    assert_equal 3, table[:content].size, "header + two body rows"

    header = table[:content].first
    assert_equal "tableRow", header[:type]
    assert_equal %w[tableHeader tableHeader], header[:content].map { |c| c[:type] }
    assert_equal "Filter", header[:content].first[:content].first[:content].first[:text]

    body = table[:content].last
    assert_equal %w[tableCell tableCell], body[:content].map { |c| c[:type] }
    assert_equal "Within a range", body[:content].last[:content].first[:content].first[:text]
  end

  test "table cells keep their inline marks" do
    d = doc("| A | B |\n| --- | --- |\n| **bold** | `code` |")

    cell_marks = d[:content].first[:content].last[:content].map { |c| c[:content].first[:content].first[:marks] }
    assert_equal "strong", cell_marks.first.first[:type]
    assert_equal "code", cell_marks.last.first[:type]
  end

  test "a short row is padded so the ADF table stays rectangular" do
    d = doc("| A | B | C |\n| --- | --- | --- |\n| only one |")

    assert_equal 3, d[:content].first[:content].last[:content].size
  end

  test "an escaped pipe stays inside its cell" do
    d = doc("| A | B |\n| --- | --- |\n| public \\| private | x |")

    first_cell = d[:content].first[:content].last[:content].first
    assert_equal "public | private", first_cell[:content].first[:content].first[:text]
  end

  test "pipes without a divider row stay prose, not a table" do
    d = doc("this | that | other")

    assert_equal "paragraph", d[:content].first[:type]
  end

  test "--- becomes a rule instead of a literal paragraph" do
    d = doc("Above\n\n---\n\nBelow")

    assert_equal %w[paragraph rule paragraph], d[:content].map { |b| b[:type] }
  end

  test "a rule directly under a paragraph still separates them" do
    d = doc("Above\n---\nBelow")

    assert_equal %w[paragraph rule paragraph], d[:content].map { |b| b[:type] }
  end

  test "the real brief shape converts without leaving raw markdown" do
    md = <<~MD
      **Problem/value:** One phone is required.

      **Acceptance (high level):**
      - Hint is visible before submit.
      - Wording makes it clear.

      **References:** https://www.loom.com/share/abc?sid=1
    MD
    json = doc(md).to_json
    refute json.include?("**"), "no literal bold markers should survive"
    assert json.include?("bulletList")
    assert json.include?("\"strong\"")
    assert json.include?("\"link\"")
  end
end
