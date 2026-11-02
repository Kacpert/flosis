import { Controller } from "@hotwired/stimulus"

// Puts an older version of a prompt back into the edit form's textarea.
//
// It fills the field rather than saving: restoring a prompt is an edit like any
// other, so it goes through the same review and the same Save button — and if
// it was the wrong version, closing the modal changes nothing.
export default class extends Controller {
  static targets = ["field", "notice"]

  restore(event) {
    const prompt = event.currentTarget.dataset.prompt
    if (!this.hasFieldTarget || prompt == null) return

    this.fieldTarget.value = prompt
    this.fieldTarget.dispatchEvent(new Event("input", { bubbles: true }))
    this.fieldTarget.focus()
    this.fieldTarget.setSelectionRange(0, 0)
    this.fieldTarget.scrollIntoView({ block: "nearest" })

    if (this.hasNoticeTarget) {
      this.noticeTarget.hidden = false
    }
  }
}
