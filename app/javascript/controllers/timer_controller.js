import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["display"]
  static values = { startedAt: String }

  connect() {
    if (this.startedAtValue) {
      this.startTime = new Date(this.startedAtValue)
      this.tick()
      this.interval = setInterval(() => this.tick(), 1000)
    }
  }

  disconnect() {
    if (this.interval) clearInterval(this.interval)
  }

  tick() {
    const elapsed = Math.floor((Date.now() - this.startTime.getTime()) / 1000)
    const hours = Math.floor(elapsed / 3600)
    const minutes = Math.floor((elapsed % 3600) / 60)
    const seconds = elapsed % 60

    const display = `${String(hours).padStart(2, '0')}:${String(minutes).padStart(2, '0')}:${String(seconds).padStart(2, '0')}`

    if (this.hasDisplayTarget) {
      this.displayTarget.textContent = display
    }

    // Update page title with timer
    document.title = `${display} - Gold`
  }
}
