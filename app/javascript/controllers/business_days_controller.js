import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["startDate", "endDate", "count"]

  compute() {
    const start = this.startDateTarget.value
    const end = this.endDateTarget.value

    if (!start || !end) {
      this.countTarget.textContent = "-"
      return
    }

    const startDate = new Date(start)
    const endDate = new Date(end)

    if (endDate < startDate) {
      this.countTarget.textContent = "0"
      return
    }

    let count = 0
    const current = new Date(startDate)
    while (current <= endDate) {
      const day = current.getDay()
      if (day !== 0 && day !== 6) count++
      current.setDate(current.getDate() + 1)
    }

    this.countTarget.textContent = count
  }
}
