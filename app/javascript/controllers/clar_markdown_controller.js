import { Controller } from "@hotwired/stimulus"
import { renderMarkdown } from "lib/clar_markdown"

// Renders this element's plain-text content as Markdown -> HTML on connect,
// using the shared conservative regex renderer (app/javascript/lib/clar_markdown.js).
// The server renders the raw text as textContent (so it's already HTML-safe
// by construction); this controller replaces it with the rendered markup.
export default class extends Controller {
  connect() {
    this.element.innerHTML = renderMarkdown(this.element.textContent)
  }
}
