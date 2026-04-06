import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["row", "detail", "arrow"]

  toggle(event) {
    const clickedRow = event.currentTarget
    const idx = clickedRow.dataset.rowIndex

    // If already expanded, collapse it
    const detail = this.detailTargets.find(d => d.dataset.rowIndex === idx)
    const arrow = this.arrowTargets.find(a => a.dataset.rowIndex === idx)

    if (detail && !detail.classList.contains("hidden")) {
      detail.classList.add("hidden")
      if (arrow) arrow.classList.remove("rotate-90")
      return
    }

    // Collapse all others
    this.detailTargets.forEach(d => d.classList.add("hidden"))
    this.arrowTargets.forEach(a => a.classList.remove("rotate-90"))

    // Expand clicked
    if (detail) detail.classList.remove("hidden")
    if (arrow) arrow.classList.add("rotate-90")
  }

  stopPropagation(event) {
    event.stopPropagation()
  }
}
