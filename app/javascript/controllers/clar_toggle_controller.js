import { Controller } from "@hotwired/stimulus"

// Generic boolean switch (the .clar-toggle pill button + knob). Wraps a
// hidden checkbox so the surrounding <form> submits the value normally —
// the button itself is never a form control, just a visual/aria proxy.
// Used by the Configuration -> Integrations manage modals (GitHub's
// "AI PR reviews on this repo", Figma's read toggle).
export default class extends Controller {
  static targets = ["input", "button"]

  toggle() {
    this.inputTarget.checked = !this.inputTarget.checked
    this.render()
  }

  render() {
    this.buttonTarget.setAttribute("aria-checked", this.inputTarget.checked ? "true" : "false")
  }
}
