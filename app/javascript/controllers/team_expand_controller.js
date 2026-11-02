import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["panel", "arrow"]

  toggle() {
    this.panelTarget.classList.toggle("hidden")
    this.arrowTarget.textContent = this.panelTarget.classList.contains("hidden") ? "▾" : "▴"
  }
}
