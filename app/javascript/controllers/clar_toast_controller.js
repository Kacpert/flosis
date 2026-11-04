import { Controller } from "@hotwired/stimulus"

// Global toast for the Clar workshop shell. Any controller (or the server,
// via a flash-seeded initial value) can trigger a toast by dispatching a
// window "clar:toast" CustomEvent with { detail: { message } }. The server's
// may carry a link (the Designs import's page once master is ready), shown
// as Open and given time to be clicked.
export default class extends Controller {
  static targets = ["toast", "message", "link"]
  static values = { initial: String, link: String }

  connect() {
    this.boundShowFromEvent = this.showFromEvent.bind(this)
    window.addEventListener("clar:toast", this.boundShowFromEvent)

    if (this.hasInitialValue && this.initialValue) {
      this.show(this.initialValue, this.linkValue)
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

  show(message, link = "") {
    if (!this.hasToastTarget) return
    if (this.hasMessageTarget) this.messageTarget.textContent = message
    if (this.hasLinkTarget) {
      this.linkTarget.classList.toggle("hidden", !link)
      if (link) this.linkTarget.href = link
    }

    this.toastTarget.classList.remove("hidden")
    clearTimeout(this.hideTimeout)
    this.hideTimeout = setTimeout(() => {
      this.toastTarget.classList.add("hidden")
    }, link ? 8000 : 2600)
  }
}
