import { Controller } from "@hotwired/stimulus"

// Reloads the document turbo-frame (the right-hand Brief / Description panel)
// when the chat saves a new version. The chat controller fires a window-level
// `clar:document-updated` event after a brief/draft is persisted; without this
// listener the event went nowhere, so a brief saved mid-conversation never
// appeared until a full page refresh (the panel kept showing the stale version).
//
// The frame has no `src` at page load (its content is rendered inline, so no
// load-time refetch). On the event we set `src` to the reload URL, which makes
// Turbo do a frame-scoped GET and swap in the fresh `#clar-document` fragment
// from `show`. Reloading with no ?v= re-renders the current (newest) version,
// which is what the AI just make_current!d.
export default class extends Controller {
  static values = { reloadUrl: String }

  connect() {
    this.boundRefresh = this.refresh.bind(this)
    window.addEventListener("clar:document-updated", this.boundRefresh)
  }

  disconnect() {
    window.removeEventListener("clar:document-updated", this.boundRefresh)
  }

  refresh() {
    const frame = this.element
    if (this.reloadUrlValue) {
      // Force a fetch even if src is unchanged (removeAttribute("complete")).
      frame.removeAttribute("complete")
      frame.src = this.reloadUrlValue
    } else if (typeof frame.reload === "function") {
      frame.reload()
    }
  }
}
