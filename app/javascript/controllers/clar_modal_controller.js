import { Controller } from "@hotwired/stimulus"

// Generic modal for the Clar workshop shell — replaces per-feature modal
// wiring. The controller sits on a wrapper containing both the trigger
// (e.g. an entry card with data-action="clar-modal#open") and the modal
// overlay itself (marked data-clar-modal-target="panel", starts .hidden).
// Backdrop click closes; clicks on the panel itself don't bubble to the
// backdrop; Escape closes; body scroll is locked while open.
export default class extends Controller {
  static targets = ["panel"]

  connect() {
    this.boundKeydown = this.handleKeydown.bind(this)
  }

  disconnect() {
    document.removeEventListener("keydown", this.boundKeydown)
    document.body.style.overflow = ""
  }

  open(event) {
    if (event) event.preventDefault()
    this.panelTarget.classList.remove("hidden")
    document.addEventListener("keydown", this.boundKeydown)
    document.body.style.overflow = "hidden"
  }

  close() {
    this.panelTarget.classList.add("hidden")
    document.removeEventListener("keydown", this.boundKeydown)
    document.body.style.overflow = ""
  }

  stopPropagation(event) {
    event.stopPropagation()
  }

  handleKeydown(event) {
    if (event.key === "Escape") this.close()
  }
}
