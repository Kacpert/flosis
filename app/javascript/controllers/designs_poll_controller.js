import { Controller } from "@hotwired/stimulus"

// Keeps the Designs chat current while a turn is queued or running: the chat
// frame reloads every two seconds, by dropping `complete` and setting `src` as
// clar_document_refresh_controller does. Each reload replaces this element, so
// the state last seen is kept on the frame, which stays.
//
// When a reload shows the turn has ended — nothing active any more, or a new
// commit — the whole screen refreshes (Ruling P2-R27): a turn changes the
// count, Approve, the context pills and the preview, not only the chat.
export default class extends Controller {
  static values = { active: Boolean, commit: String, url: String }

  connect() {
    const frame = this.element.closest("turbo-frame")
    const before = frame.dataset.designsSeen && JSON.parse(frame.dataset.designsSeen)
    frame.dataset.designsSeen = JSON.stringify({ active: this.activeValue, commit: this.commitValue })

    if (before && ((before.active && !this.activeValue) || before.commit !== this.commitValue)) {
      window.Turbo.visit(window.location.href, { action: "replace" })
      return
    }
    if (this.activeValue) this.timer = setTimeout(() => this.reload(frame), 2000)
  }

  disconnect() {
    clearTimeout(this.timer)
  }

  reload(frame) {
    frame.removeAttribute("complete")
    frame.src = this.urlValue
  }
}
