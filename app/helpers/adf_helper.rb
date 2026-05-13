module AdfHelper
  def adf_to_html(json_string, attachments: nil)
    return "" if json_string.blank?

    @adf_attachment_map = build_attachment_map(attachments)
    node = JSON.parse(json_string)
    html = render_adf_node(node)
    sanitize(
      html,
      tags: %w[p h1 h2 h3 h4 h5 h6 strong em u s a ul ol li blockquote pre code br hr span img button div figure figcaption],
      attributes: %w[href target rel class src alt style data-action data-lightbox-src-param data-lightbox-caption-param type aria-label]
    )
  rescue JSON::ParserError
    simple_format(h(json_string))
  end

  private

  def build_attachment_map(attachments)
    return {} if attachments.blank?
    attachments.each_with_object({}) do |att, h|
      jira_id = att.blob.metadata["jira_id"].to_s
      h[jira_id] = att if jira_id.present?
    end
  end

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
    when "mediaSingle", "mediaGroup"
      "<div class=\"adf-media\" style=\"margin: 0.75rem 0;\">#{children_html}</div>"
    when "media"
      render_media_node(node)
    when "mediaInline"
      render_media_node(node)
    else
      children_html
    end
  end

  def render_media_node(node)
    jira_id = node.dig("attrs", "id").to_s
    return "" if jira_id.blank?

    att = (@adf_attachment_map || {})[jira_id]
    return "" unless att

    if att.content_type.to_s.start_with?("image/")
      url = rails_blob_path(att, disposition: "inline")
      filename = ERB::Util.html_escape(att.filename.to_s)
      <<~HTML
        <button type="button" class="adf-media-image" data-action="click->lightbox#open" data-lightbox-src-param="#{url}" data-lightbox-caption-param="#{filename}" style="display: inline-block; padding: 0; background: none; border: 0; cursor: zoom-in;">
          <img src="#{url}" alt="#{filename}" style="max-width: 100%; max-height: 360px; height: auto; border-radius: 6px; border: 1px solid var(--color-outline-variant);" loading="lazy">
        </button>
      HTML
    else
      url = rails_blob_path(att, disposition: "inline")
      filename = ERB::Util.html_escape(att.filename.to_s)
      "<a href=\"#{url}\" target=\"_blank\" rel=\"noopener\">📎 #{filename}</a>"
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
