import { Controller } from "@hotwired/stimulus"

// Client-side text filter for the Jira board browser. Matches against each
// card's (kanban) or row's (Backlog table) precomputed
// data-clar-board-filter-text attribute — key + title + assignee + reporter,
// lowercased server-side. Both tabs get the search box.
export default class extends Controller {
  static targets = ["input", "card", "row"]

  filter() {
    const query = this.inputTarget.value.trim().toLowerCase()

    ;[...this.cardTargets, ...this.rowTargets].forEach((el) => {
      const haystack = el.dataset.clarBoardFilterText || ""
      el.classList.toggle("hidden", query.length > 0 && !haystack.includes(query))
    })
  }
}
