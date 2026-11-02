import { Controller } from "@hotwired/stimulus"

// Paints a square tick box over a visually-hidden checkbox. The real input
// stays in the form (and keeps its native label/keyboard behaviour) — this
// only mirrors its state, so the value submits normally.
const CHECK = '<svg width="11" height="11" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3"><path d="M20 6L9 17l-5-5"/></svg>'

export default class extends Controller {
  static targets = ["input", "box"]

  connect() {
    this.render()
    this.onChange = () => this.render()
    this.inputTarget.addEventListener("change", this.onChange)
  }

  disconnect() {
    this.inputTarget.removeEventListener("change", this.onChange)
  }

  render() {
    const on = this.inputTarget.checked
    this.boxTarget.style.borderColor = on ? "var(--primary)" : "var(--border)"
    this.boxTarget.style.background = on ? "var(--primary)" : "transparent"
    this.boxTarget.innerHTML = on ? CHECK : ""
  }
}
