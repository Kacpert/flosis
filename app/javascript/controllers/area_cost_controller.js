import { Controller } from "@hotwired/stimulus"

// An area's AI cost for a chosen month (SCRUM-70, workshop/shared/_area_cost):
// picking another month swaps the figure and its run count, nothing else.
// Each option's value is "amount|runs".
export default class extends Controller {
  static targets = ["month", "amount", "runs"]

  pick() {
    const [amount, runs] = this.monthTarget.value.split("|")
    this.amountTarget.textContent = "$" + Number(amount).toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 })
    this.runsTarget.textContent = runs
  }
}
