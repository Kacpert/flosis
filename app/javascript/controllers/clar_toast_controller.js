import { Controller } from "@hotwired/stimulus"

// Global toast for the Clar workshop shell. Any controller (or the server,
// via a flash-seeded initial value) can trigger a toast by dispatching a
// window "clar:toast" CustomEvent with { detail: { message } }.
export default class extends Controller {
  static targets = ["toast", "message"]
  static values = { initial: String }

  connect() {
    this.boundShowFromEvent = this.showFromEvent.bind(this)
    window.addEventListener("clar:toast", this.boundShowFromEvent)

    if (this.hasInitialValue && this.initialValue) {
      this.show(this.initialValue)
    }
  }

  disconnect() {
    window.removeEventListener("clar:toast", this.boundShowFromEvent)
    clearTimeout(this.hideTimeout)
  }

  showFromEvent(event) {
    const message = event.detail && event.detail.message
    if (message) this.show(message)
  }

  show(message) {
    if (!this.hasToastTarget) return
    if (this.hasMessageTarget) this.messageTarget.textContent = message

    this.toastTarget.classList.remove("hidden")
    clearTimeout(this.hideTimeout)
    this.hideTimeout = setTimeout(() => {
      this.toastTarget.classList.add("hidden")
    }, 2600)
  }
}
