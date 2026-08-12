import { Controller } from "@hotwired/stimulus"

// Alert rule modal: lets a row of channel "chips" act like a radio group
// without a native <select> — clicking a chip checks its underlying radio input
// and restyles the row. (Scheduling lives in clar_schedule_builder_controller.)
export default class extends Controller {
  static targets = ["channelRadio", "channelChip"]

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
