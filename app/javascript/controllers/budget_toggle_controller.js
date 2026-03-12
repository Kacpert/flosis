import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["budgetType", "hoursField", "moneyField"]

  connect() {
    this.toggle()
  }

  toggle() {
    const type = this.budgetTypeTarget.value

    this.hoursFieldTarget.classList.toggle("hidden", type !== "hours")
    this.moneyFieldTarget.classList.toggle("hidden", type !== "money")
  }
}
