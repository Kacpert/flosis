import { Controller } from "@hotwired/stimulus"

// A design thread's composer: Enter sends, Shift+Enter breaks the line.
export default class extends Controller {
  key(event) {
    if (event.key !== "Enter" || event.shiftKey || event.isComposing) return
    event.preventDefault()
    if (this.element.value.trim()) this.element.form.requestSubmit()
  }
}
