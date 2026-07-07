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
