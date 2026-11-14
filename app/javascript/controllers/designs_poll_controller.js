import { Controller } from "@hotwired/stimulus"

// Keeps the Designs chat current while a turn is queued or running: the chat
// frame reloads every two seconds, by dropping `complete` and setting `src` as
// clar_document_refresh_controller does. Each reload replaces this element, so
// the state last seen is kept on the frame, which stays.
//
// When a reload shows the turn has ended — nothing active any more, or a new
// commit — the whole screen refreshes (Ruling P2-R27): a turn changes the
// count, Approve, the context pills and the preview, not only the chat.
//
// A reload keeps what the reader had: where the chat was scrolled to (the
// bottom, when they were there, so each new step of the turn comes into view)
// and which folds (details[data-keep]) were open. A chat opens at its latest.
// The replies inside draw their Markdown as they connect, after this
// controller, so the chat is scrolled once they have: on the next frame,
// still before it is painted.
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
    requestAnimationFrame(() => this.restore(frame))
    if (this.activeValue) this.timer = setTimeout(() => this.reload(frame), 2000)
  }

  disconnect() {
    clearTimeout(this.timer)
  }

  reload(frame) {
    this.keep(frame)
    frame.removeAttribute("complete")
    frame.src = this.urlValue
  }

  keep(frame) {
    const chat = this.element
    const open = [...chat.querySelectorAll("details[data-keep][open]")].map((fold) => fold.dataset.keep)
    const bottom = chat.scrollHeight - chat.scrollTop - chat.clientHeight < 40
    frame.dataset.designsView = JSON.stringify({ top: chat.scrollTop, bottom, open })
  }

  restore(frame) {
    const chat = this.element
    const view = frame.dataset.designsView && JSON.parse(frame.dataset.designsView)
    delete frame.dataset.designsView
    if (!view) {
      chat.scrollTop = chat.scrollHeight
      return
    }
    view.open.forEach((key) => {
      const fold = [...chat.querySelectorAll("details[data-keep]")].find((element) => element.dataset.keep === key)
      if (fold) fold.open = true
    })
    chat.scrollTop = view.bottom ? chat.scrollHeight : view.top
  }
}
