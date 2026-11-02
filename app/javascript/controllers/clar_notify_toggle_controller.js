import { Controller } from "@hotwired/stimulus"

// Notification opt-in for an AI Alert / Automation form. A .clar-toggle pill
// switch (button + knob) wraps a hidden checkbox so the <form> submits the
// value normally; flipping it ON both flags aria-checked (drives the switch
// visual) and reveals the Discord-channel picker. OFF hides the channels and
// the automation simply posts nothing.
export default class extends Controller {
  static targets = ["input", "button", "channels"]

  toggle() {
    this.inputTarget.checked = !this.inputTarget.checked
    this.sync()
  }

  sync() {
    const on = this.hasInputTarget ? this.inputTarget.checked : false
    if (this.hasButtonTarget) this.buttonTarget.setAttribute("aria-checked", on ? "true" : "false")
    if (this.hasChannelsTarget) this.channelsTarget.classList.toggle("hidden", !on)
  }
}
