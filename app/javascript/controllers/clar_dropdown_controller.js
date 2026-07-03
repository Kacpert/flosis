import { Controller } from "@hotwired/stimulus"

// Generic dropdown (project switcher, etc.) for the Clar workshop shell.
// Opens/closes a panel target, closing on outside click or Escape.
export default class extends Controller {
  static targets = ["panel"]

  connect() {
    this.boundClose = this.close.bind(this)
    this.boundKeydown = this.handleKeydown.bind(this)
  }

  disconnect() {
    document.removeEventListener("click", this.boundClose)
    document.removeEventListener("keydown", this.boundKeydown)
  }

  toggle(event) {
    event.stopPropagation()
    if (this.isOpen) {
      this.close()
    } else {
      this.open()
    }
  }

  open() {
    if (!this.hasPanelTarget) return
    this.panelTarget.classList.remove("hidden")
    document.addEventListener("click", this.boundClose)
    document.addEventListener("keydown", this.boundKeydown)
  }

  close() {
    if (!this.hasPanelTarget) return
    this.panelTarget.classList.add("hidden")
    document.removeEventListener("click", this.boundClose)
    document.removeEventListener("keydown", this.boundKeydown)
  }

  handleKeydown(event) {
    if (event.key === "Escape") this.close()
  }

  get isOpen() {
    return this.hasPanelTarget && !this.panelTarget.classList.contains("hidden")
  }
}
