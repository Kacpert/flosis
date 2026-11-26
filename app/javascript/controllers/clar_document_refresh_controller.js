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
//
// When the reload brings a newer current version than the panel showed, the
// panel glows softly and the version's chip pulses (Kacper, 2026-11-26: "nie
// wiem kiedy to się dzieje"). The chat's AI cost uses the same reload, and
// has no version to compare.
const UPDATED_CLASS = "clar-document-updated"
const UPDATED_MS = 2600

export default class extends Controller {
  static values = { reloadUrl: String }

  connect() {
    this.boundRefresh = this.refresh.bind(this)
    this.boundLoaded = this.loaded.bind(this)
    window.addEventListener("clar:document-updated", this.boundRefresh)
    this.element.addEventListener("turbo:frame-load", this.boundLoaded)
  }

  disconnect() {
    window.removeEventListener("clar:document-updated", this.boundRefresh)
    this.element.removeEventListener("turbo:frame-load", this.boundLoaded)
    clearTimeout(this.updatedTimer)
  }

  refresh() {
    this.before = this.currentVersion()
    const frame = this.element
    if (this.reloadUrlValue) {
      // Force a fetch even if src is unchanged (removeAttribute("complete")).
      frame.removeAttribute("complete")
      frame.src = this.reloadUrlValue
    } else if (typeof frame.reload === "function") {
      frame.reload()
    }
  }

  loaded() {
    const before = this.before
    this.before = undefined
    const now = this.currentVersion()
    if (before === undefined || before === null || now === null || now === before) return

    const panel = this.element.querySelector("[data-clar-document-current]")
    panel.classList.add(UPDATED_CLASS)
    clearTimeout(this.updatedTimer)
    this.updatedTimer = setTimeout(() => panel.classList.remove(UPDATED_CLASS), UPDATED_MS)
  }

  // The current version the panel shows, or null where there is none (the
  // chat's AI cost).
  currentVersion() {
    const panel = this.element.querySelector("[data-clar-document-current]")
    return panel ? panel.dataset.clarDocumentCurrent : null
  }
}
