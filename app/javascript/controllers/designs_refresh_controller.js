import { Controller } from "@hotwired/stimulus"

// Reloads the page now and then while something runs in the background (the
// Designs setup's progress, an import's page). A reply being written is never
// thrown away: while a field on the page has focus or text in it, the reload
// waits for the next turn.
export default class extends Controller {
  static values = { interval: { type: Number, default: 15000 } }

  connect() {
    this.schedule()
  }

  disconnect() {
    clearTimeout(this.timer)
  }

  schedule() {
    this.timer = setTimeout(() => this.refresh(), this.intervalValue)
  }

  refresh() {
    const fields = [ ...this.element.querySelectorAll("textarea, input[type=text]") ]
    const writing = fields.some((field) => field === document.activeElement || field.value.trim() !== "")
    writing ? this.schedule() : window.Turbo.visit(window.location.href, { action: "replace" })
  }
}
