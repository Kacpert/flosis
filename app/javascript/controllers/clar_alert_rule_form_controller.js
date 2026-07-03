import { Controller } from "@hotwired/stimulus"

// New alert rule modal (Task 6.4): disables the TIME input while FREQUENCY is
// "hourly" (an hourly rule has no fixed time-of-day), and lets a row of
// channel "chips" act like a radio group without a native <select> — clicking
// a chip checks its underlying radio input and restyles the row.
export default class extends Controller {
  static targets = ["frequency", "time", "channelRadio", "channelChip"]

  connect() {
    this.syncTimeDisabled()
  }

  syncTimeDisabled() {
    if (!this.hasFrequencyTarget || !this.hasTimeTarget) return
    const hourly = this.frequencyTarget.value === "hourly"
    this.timeTarget.disabled = hourly
    this.timeTarget.classList.toggle("opacity-50", hourly)
  }

  selectChannel(event) {
    const chip = event.currentTarget
    const radio = chip.querySelector('input[type="radio"]')
    if (!radio) return
    radio.checked = true
    this.channelChipTargets.forEach((c) => {
      const active = c === chip
      c.classList.toggle("clar-chip-active", active)
    })
  }
}
