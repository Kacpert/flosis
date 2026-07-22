import { Controller } from "@hotwired/stimulus"

// Simple client-side list filter. The input types into `query`; each element
// marked data-clar-filter-target="item" is shown/hidden by a case-insensitive
// substring match against its data-filter-text (falling back to textContent).
// An optional data-clar-filter-target="empty" element shows when nothing matches.
export default class extends Controller {
  static targets = ["query", "item", "empty"]

  connect() {
    this.filter()
  }

  filter() {
    const q = (this.hasQueryTarget ? this.queryTarget.value : "").trim().toLowerCase()
    let shown = 0
    this.itemTargets.forEach((el) => {
      const hay = (el.dataset.filterText || el.textContent || "").toLowerCase()
      const match = q === "" || hay.includes(q)
      el.classList.toggle("hidden", !match)
      if (match) shown++
    })
    if (this.hasEmptyTarget) this.emptyTarget.classList.toggle("hidden", shown !== 0)
  }
}
