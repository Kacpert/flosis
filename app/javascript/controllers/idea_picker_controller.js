import { Controller } from "@hotwired/stimulus"

// Step 1 of the Idea → Brief pipeline: choose ONE mode (existing task or new
// idea) and see only that mode's input. The existing-task list is filtered
// client-side as you type.
export default class extends Controller {
  static targets = ["existingPanel", "newPanel", "existingTab", "newTab", "search", "item", "empty"]
  static values = { mode: String }

  connect() {
    // Honor the mode chosen on the landing; fall back to existing when there are
    // tasks, else new idea.
    const initial = this.modeValue || (this.hasItemTarget ? "existing" : "new")
    this.show(initial)
  }

  showExisting() { this.show("existing") }
  showNew() { this.show("new") }

  show(mode) {
    const existing = mode === "existing"
    this.existingPanelTarget.hidden = !existing
    this.newPanelTarget.hidden = existing
    this.existingTabTarget.classList.toggle("idea-tab-active", existing)
    this.newTabTarget.classList.toggle("idea-tab-active", !existing)
    if (existing && this.hasSearchTarget) this.searchTarget.focus()
  }

  filter() {
    const q = this.searchTarget.value.trim().toLowerCase()
    let visible = 0
    this.itemTargets.forEach((el) => {
      const match = el.dataset.label.toLowerCase().includes(q)
      el.hidden = !match
      if (match) visible++
    })
    if (this.hasEmptyTarget) this.emptyTarget.hidden = visible !== 0
  }
}
