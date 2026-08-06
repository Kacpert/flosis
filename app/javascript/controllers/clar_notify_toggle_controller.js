import { Controller } from "@hotwired/stimulus"

// Notification opt-in for an AI Alert / Automation form: a switch (checkbox)
// that reveals the Discord-channel picker only when notifications are ON. When
// off, the channels are hidden (and the automation simply posts nothing).
export default class extends Controller {
  static targets = ["toggle", "channels"]

  connect() {
    this.sync()
  }

  sync() {
    const on = this.hasToggleTarget ? this.toggleTarget.checked : false
    if (this.hasChannelsTarget) this.channelsTarget.classList.toggle("hidden", !on)
  }
}
