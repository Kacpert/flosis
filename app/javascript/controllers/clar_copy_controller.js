import { Controller } from "@hotwired/stimulus"

// Generic clipboard-copy button (Task 5.4's Ready screen "AI prepared a
// branch" card copies `git checkout {branch}`, not just the branch name).
// The value to copy lives on the controller's data-clar-copy-value attribute
// so this controller has no knowledge of what it's copying. On success,
// dispatches the same window "clar:toast" event used elsewhere (see
// clar_rename_controller.js / clar_toast_controller.js).
export default class extends Controller {
  static values = { value: String, message: { type: String, default: "Checkout command copied" } }

  copy() {
    const text = this.valueValue

    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(text).then(() => this.announce(), () => this.fallbackCopy(text))
    } else {
      this.fallbackCopy(text)
    }
  }

  fallbackCopy(text) {
    const textarea = document.createElement("textarea")
    textarea.value = text
    textarea.style.position = "fixed"
    textarea.style.opacity = "0"
    document.body.appendChild(textarea)
    textarea.focus()
    textarea.select()

    try {
      document.execCommand("copy")
    } catch (e) {
      // clipboard unavailable — nothing more we can do
    }

    document.body.removeChild(textarea)
    this.announce()
  }

  announce() {
    window.dispatchEvent(new CustomEvent("clar:toast", { detail: { message: this.messageValue } }))
  }
}
