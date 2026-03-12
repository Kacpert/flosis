import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["dollars", "cents"]

  connect() {
    const cents = parseInt(this.centsTarget.value) || 0
    if (cents > 0) {
      this.dollarsTarget.value = (cents / 100).toFixed(2)
    }
  }

  update() {
    const dollars = parseFloat(this.dollarsTarget.value) || 0
    this.centsTarget.value = Math.round(dollars * 100)
  }
}
