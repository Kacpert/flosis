require "test_helper"

# The rich-text editor saves a description as HTML; Jira and a task's file get
# it as Markdown, so its headings, bold and links survive (2026-11-21).
class HtmlToMarkdownTest < ActiveSupport::TestCase
  test "headings, bold and paragraphs become Markdown" do
    html = "<h2>AI usage and cost</h2><p>Flosis runs <b>Claude</b> in <i>many</i> places.</p><p>Second <strong>one</strong>.</p>"
    assert_equal "## AI usage and cost\n\nFlosis runs **Claude** in _many_ places.\n\nSecond **one**.", HtmlToMarkdown.call(html)
  end

  test "a link keeps its address" do
    assert_equal "See [the designs](https://app.flosis.test/a/b/SCRUM-70/design) now.",
                 HtmlToMarkdown.call(%(<p>See <a href="https://app.flosis.test/a/b/SCRUM-70/design">the designs</a> now.</p>))
    assert_equal "Just text", HtmlToMarkdown.call("<p><a>Just text</a></p>")
  end

  test "dash paragraphs join into one list" do
    html = "<p><b>Plans (Flosis admin)</b></p><p>- Admin creates a plan.</p><p>- Admin picks models.</p><p>After.</p>"
    assert_equal "**Plans (Flosis admin)**\n\n- Admin creates a plan.\n- Admin picks models.\n\nAfter.", HtmlToMarkdown.call(html)
  end

  test "checkbox paragraphs join too" do
    html = "<p><b>Acceptance criteria</b></p><p>- [ ] One.</p><p>- [ ] Two.</p>"
    assert_equal "**Acceptance criteria**\n\n- [ ] One.\n- [ ] Two.", HtmlToMarkdown.call(html)
  end

  test "lists, breaks, code and quotes" do
    html = "<ul><li>a</li><li>b <b>bold</b></li></ul><ol><li>first</li><li>second</li></ol>" \
           "<p>line<br>next</p><p>use <code>bin/dev</code></p><pre>x = 1\ny = 2</pre><blockquote><p>quoted</p></blockquote><hr>"
    assert_equal "- a\n- b **bold**\n\n1. first\n2. second\n\nline\nnext\n\nuse `bin/dev`\n\n```\nx = 1\ny = 2\n```\n\n> quoted\n\n---",
                 HtmlToMarkdown.call(html)
  end

  test "empty paragraphs and entities" do
    html = "<p>Tom &amp; Jerry &lt;3</p><p><br></p><p>&nbsp;</p><p>End</p>"
    assert_equal "Tom & Jerry <3\n\nEnd", HtmlToMarkdown.call(html)
  end

  test "script and style contents never come through" do
    html = "<p>Hi</p><script>alert(1)</script><style>p{color:red}</style><p>x<script>bad()</script></p>"
    assert_equal "Hi\n\nx", HtmlToMarkdown.call(html)
  end

  test "blank input is blank" do
    assert_equal "", HtmlToMarkdown.call(nil)
    assert_equal "", HtmlToMarkdown.call("")
  end
end
