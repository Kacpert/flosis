import { Controller } from "@hotwired/stimulus"

// The plan form's worked example (SCRUM-70): what a $10.00 run is charged at
// the margin being typed.
export default class extends Controller {
  static targets = ["margin", "example"]

  show() {
    const margin = parseFloat(this.marginTarget.value) || 0
    this.exampleTarget.textContent = "$" + (10 * (1 + margin / 100)).toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 })
  }
}
