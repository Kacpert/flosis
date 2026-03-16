module AdfHelper
  def adf_to_html(json_string)
    return "" if json_string.blank?

    node = JSON.parse(json_string)
    html = render_adf_node(node)
    sanitize(html, tags: %w[p h1 h2 h3 h4 h5 h6 strong em u s a ul ol li blockquote pre code br hr span], attributes: %w[href target rel class])
  rescue JSON::ParserError
    simple_format(h(json_string))
  end

  private

  def render_adf_node(node)
    return "" if node.nil?
    return render_text_node(node) if node["type"] == "text"

    children_html = (node["content"] || []).map { |child| render_adf_node(child) }.join

    case node["type"]
    when "doc"
      children_html
    when "paragraph"
      "<p>#{children_html}</p>"
    when "heading"
      level = node.dig("attrs", "level") || 2
      "<h#{level}>#{children_html}</h#{level}>"
    when "bulletList"
      "<ul>#{children_html}</ul>"
    when "orderedList"
      "<ol>#{children_html}</ol>"
    when "listItem"
      "<li>#{children_html}</li>"
    when "blockquote"
      "<blockquote>#{children_html}</blockquote>"
    when "codeBlock"
      "<pre><code>#{children_html}</code></pre>"
    when "rule"
      "<hr>"
    when "hardBreak"
      "<br>"
    else
      children_html
    end
  end

  def render_text_node(node)
    text = ERB::Util.html_escape(node["text"] || "")
    marks = node["marks"] || []

    marks.each do |mark|
      case mark["type"]
      when "strong"
        text = "<strong>#{text}</strong>"
      when "em"
        text = "<em>#{text}</em>"
      when "underline"
        text = "<u>#{text}</u>"
      when "strike"
        text = "<s>#{text}</s>"
      when "code"
        text = "<code>#{text}</code>"
      when "link"
        href = ERB::Util.html_escape(mark.dig("attrs", "href") || "")
        text = "<a href=\"#{href}\" target=\"_blank\" rel=\"noopener\">#{text}</a>"
      end
    end

    text
  end
end
