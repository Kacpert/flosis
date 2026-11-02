import { Controller } from "@hotwired/stimulus"

// Toggles a submit button's disabled state based on whether a required input
// has a non-blank value. Used by modals (e.g. the new-idea modal) where
// "Save" should stay disabled until the title is filled in.
export default class extends Controller {
  static targets = ["input", "submit"]

  connect() {
    this.toggle()
  }

  toggle() {
    const filled = this.inputTarget.value.trim().length > 0
    this.submitTarget.disabled = !filled
  }
}
