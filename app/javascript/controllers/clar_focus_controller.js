import { Controller } from "@hotwired/stimulus"

// Toggles the workspace grid between "normal" (chat + fixed-width document panel)
// and "focus" (document panel full-width, chat collapsed) — the full-screen
// button in the document panel header. Ported from redesign.html's panelSize
// normal|focus states: normal = "minmax(0,1fr) 460px", focus = "0 1fr".
//
// The document panel lives in a turbo-frame that reloads on version changes, so
// the toggle button re-renders; focus state therefore lives on THIS controller's
// element (the grid, outside the frame) and the button re-binds via data-action.
export default class extends Controller {
  static targets = ["grid", "chat", "expandIcon", "collapseIcon"]

  connect() {
    this.focused = false
    this.apply()
  }

  toggle() {
    this.focused = !this.focused
    this.apply()
  }

  apply() {
    if (this.hasGridTarget) {
      // Keep the resizer column, and read the width the user dragged to
      // (clar-splitter owns --clar-doc-width) instead of hard-coding 460px.
      this.gridTarget.style.gridTemplateColumns =
        this.focused ? "0 5px 1fr" : "minmax(0, 1fr) 5px var(--clar-doc-width, 460px)"
    }
    if (this.hasChatTarget) {
      this.chatTarget.classList.toggle("overflow-hidden", this.focused)
      this.chatTarget.classList.toggle("opacity-0", this.focused)
      this.chatTarget.classList.toggle("pointer-events-none", this.focused)
    }
    if (this.hasExpandIconTarget) this.expandIconTarget.classList.toggle("hidden", this.focused)
    if (this.hasCollapseIconTarget) this.collapseIconTarget.classList.toggle("hidden", !this.focused)
  }
}
