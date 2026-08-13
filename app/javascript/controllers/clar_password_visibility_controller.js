import { Controller } from "@hotwired/stimulus"

// The reveal toggle inside a password field. Swaps the input type and the
// eye/eye-off icon, and keeps the button's label in sync for screen readers.
export default class extends Controller {
  static targets = ["input", "button", "shownIcon", "hiddenIcon"]

  toggle() {
    const revealed = this.inputTarget.type === "password"
    this.inputTarget.type = revealed ? "text" : "password"
    this.shownIconTarget.classList.toggle("hidden", revealed)
    this.hiddenIconTarget.classList.toggle("hidden", !revealed)

    const label = revealed ? "Hide password" : "Show password"
    this.buttonTarget.setAttribute("title", label)
    this.buttonTarget.setAttribute("aria-label", label)
  }
}
