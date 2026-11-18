import { Controller } from "@hotwired/stimulus"
import { renderMarkdown } from "lib/clar_markdown"

// Renders this element's plain-text content as Markdown -> HTML on connect,
// using the shared conservative regex renderer (app/javascript/lib/clar_markdown.js).
// The server renders the raw text as textContent (so it's already HTML-safe
// by construction); this controller replaces it with the rendered markup.
// The text it rendered stays on the element (data-markdown-source): connected
// again over its own markup (the description editor's Cancel puts that markup
// back, and so does Turbo's cached page on Back), it renders from that text,
// not from the markup's run-together textContent.
export default class extends Controller {
  connect() {
    const source = this.element.dataset.markdownSource ?? this.element.textContent
    this.element.dataset.markdownSource = source
    this.element.innerHTML = renderMarkdown(source)
  }
}
