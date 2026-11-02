import { Controller } from "@hotwired/stimulus"

// Reloads the page now and then while something runs in the background (the
// Designs setup's progress).
export default class extends Controller {
  static values = { interval: { type: Number, default: 15000 } }

  connect() {
    this.timer = setTimeout(() => window.Turbo.visit(window.location.href, { action: "replace" }), this.intervalValue)
  }

  disconnect() {
    clearTimeout(this.timer)
  }
}
