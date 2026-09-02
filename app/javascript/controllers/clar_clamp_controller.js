import { Controller } from "@hotwired/stimulus"

// Collapses a long block of text to two lines with a toggle. Automation prompts
// run to a dozen lines each, which pushed the schedule, the channel and the
// actions of every rule below the fold.
//
// The toggle costs a line of its own, so clamping only pays from four lines up:
// two shown + a button is three, exactly what a three-line prompt takes anyway.
// Anything at or under the threshold is left whole, with no button.
// The clamp itself (2 lines) lives in .clar-clamp; this is the threshold at
// which hiding anything starts to save room.
const MIN_LINES_TO_CLAMP = 4

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
    if (!this.hasTextTarget) return

    // Measure the text unclamped — a clamped box reports the clamped height, so
    // the full length has to be read with the clamp off.
    const wasExpanded = this.expandedValue
    this.textTarget.classList.add("is-expanded")
    const lineHeight = parseFloat(getComputedStyle(this.textTarget).lineHeight) || 1
    const lines = Math.round(this.textTarget.clientHeight / lineHeight)
    this.textTarget.classList.toggle("is-expanded", wasExpanded)

    this.worthClamping = lines >= MIN_LINES_TO_CLAMP
    this.render()
  }

  render() {
    if (!this.hasTextTarget) return
    // Short enough to show whole: no clamp, no button.
    const collapsed = this.worthClamping && !this.expandedValue
    this.textTarget.classList.toggle("is-expanded", !collapsed)

    if (this.hasToggleTarget) {
      this.toggleTarget.hidden = !this.worthClamping
      this.toggleTarget.textContent = this.expandedValue ? "Show less" : "Show more"
      this.toggleTarget.setAttribute("aria-expanded", String(this.expandedValue))
    }
  }
}
