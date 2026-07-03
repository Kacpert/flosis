import { Controller } from "@hotwired/stimulus"

// Client-side text filter for the Jira board browser's kanban cards. Matches
// against each card's precomputed data-clar-board-filter-text attribute
// (key + title + assignee + reporter, lowercased server-side). Hidden on the
// Backlog tab, which has no search box and no card targets.
export default class extends Controller {
  static targets = ["input", "card"]

  filter() {
    const query = this.inputTarget.value.trim().toLowerCase()

    this.cardTargets.forEach((card) => {
      const haystack = card.dataset.clarBoardFilterText || ""
      card.classList.toggle("hidden", query.length > 0 && !haystack.includes(query))
    })
  }
}
