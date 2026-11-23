import { Controller } from "@hotwired/stimulus"

// Generic clipboard-copy button (Task 5.4's Ready screen copies
// `git checkout {branch}`). The value to copy lives on the controller's
// data-clar-copy-value attribute so this controller has no knowledge of what
// it's copying. It says "copied" only when the copy went through (the window
// "clar:toast" event, as clar_rename_controller.js does).
//
// Kacper, 2026-11-22: Copy said "copied" in Safari while nothing reached the
// clipboard. The copy now happens inside the click itself (a selected,
// read-only textarea and execCommand, which every browser honours during a
// click), then the Clipboard API; when both fail, the text on screen is
// selected so ⌘C finishes the job.
export default class extends Controller {
  static targets = ["text"]
  static values = { value: String, message: { type: String, default: "Checkout command copied" } }

  // Kacper, 2026-11-23: it still copied nothing. The view set the value as
  // data-clar-copy-value, which Stimulus does not read (data-clar-copy-value-value),
  // and an empty copy went through as copied. Nothing to copy is a failure now.
  copy() {
    const text = this.valueValue
    if (!text) return this.failed()
    if (this.copyBySelection(text)) return this.announce(this.messageValue)

    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(text).then(() => this.announce(this.messageValue), () => this.failed())
    } else {
      this.failed()
    }
  }

  copyBySelection(text) {
    const textarea = document.createElement("textarea")
    textarea.value = text
    textarea.setAttribute("readonly", "")
    Object.assign(textarea.style, { position: "fixed", top: "0", left: "0", opacity: "0", pointerEvents: "none" })
    document.body.appendChild(textarea)
    textarea.focus()
    textarea.select()
    textarea.setSelectionRange(0, text.length)

    let copied = false
    try {
      copied = document.execCommand("copy")
    } catch (e) {
      copied = false
    }
    document.body.removeChild(textarea)
    return copied
  }

  failed() {
    if (this.hasTextTarget) {
      const range = document.createRange()
      range.selectNodeContents(this.textTarget)
      const selection = window.getSelection()
      selection.removeAllRanges()
      selection.addRange(range)
    }
    this.announce("Couldn't copy · it is selected, press ⌘C")
  }

  announce(message) {
    window.dispatchEvent(new CustomEvent("clar:toast", { detail: { message } }))
  }
}
