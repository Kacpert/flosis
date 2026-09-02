import { Controller } from "@hotwired/stimulus"

// Collapses a long block of text to a few lines with a toggle. Automation
// prompts run to a dozen lines each, which pushed the schedule, the channel and
// the actions of every rule below the fold.
//
// The toggle only appears when the text is actually clipped — a two-line prompt
// gets no "Show more" that does nothing.
export default class extends Controller {
  static targets = ["text", "toggle"]
  static values = { expanded: { type: Boolean, default: false } }

  connect() {
    this.sync = this.sync.bind(this)
    window.addEventListener("resize", this.sync)
    // Fonts land after connect and change where the text wraps, so re-measure
    // once they're ready rather than hiding a toggle that turns out to be needed.
    document.fonts?.ready?.then(this.sync)
    this.sync()
  }

  disconnect() {
    window.removeEventListener("resize", this.sync)
  }

  toggle() {
    this.expandedValue = !this.expandedValue
    this.render()
  }

  sync() {
    if (!this.hasTextTarget || !this.hasToggleTarget) return
    // Measure in the collapsed state: an expanded box never overflows.
    const wasExpanded = this.expandedValue
    this.textTarget.classList.remove("is-expanded")
    this.clipped = this.textTarget.scrollHeight > this.textTarget.clientHeight + 2
    this.expandedValue = wasExpanded
    this.render()
  }

  render() {
    if (!this.hasTextTarget) return
    this.textTarget.classList.toggle("is-expanded", this.expandedValue)

    if (this.hasToggleTarget) {
      this.toggleTarget.hidden = !this.clipped && !this.expandedValue
      this.toggleTarget.textContent = this.expandedValue ? "Show less" : "Show more"
      this.toggleTarget.setAttribute("aria-expanded", String(this.expandedValue))
    }
  }
}
