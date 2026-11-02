import { Controller } from "@hotwired/stimulus"

// Drag the cards in a list into the order you want them, and remember it.
//
// The whole card is the grab area — a small handle was too fiddly to aim at.
// Dragging is armed on mousedown rather than set on the element permanently, so
// the card's own buttons, links and switches keep working: a mousedown that
// lands on one of those arms nothing, and the click goes through as usual.
const INTERACTIVE = "button, a, input, select, textarea, label, [role='button']"

export default class extends Controller {
  static targets = ["item", "handle"]
  static values = { url: String }

  connect() {
    this.dragging = null
  }

  // mousedown anywhere on a card — arm it, unless the press landed on a control.
  arm(event) {
    if (event.target.closest(INTERACTIVE)) return

    const item = event.target.closest("[data-clar-reorder-target='item']")
    if (item) item.draggable = true
  }

  disarm() {
    this.itemTargets.forEach(item => { item.draggable = false })
  }

  start(event) {
    this.dragging = event.currentTarget
    this.dragging.classList.add("is-dragging")
    // Firefox needs data set on the transfer or the drag never begins.
    event.dataTransfer.effectAllowed = "move"
    event.dataTransfer.setData("text/plain", "")
  }

  over(event) {
    if (!this.dragging) return
    event.preventDefault() // marks this a valid drop target
    event.dataTransfer.dropEffect = "move"

    const after = this.itemAfter(event.clientY)
    if (after === this.dragging) return
    if (after) {
      this.element.insertBefore(this.dragging, after)
    } else {
      this.element.appendChild(this.dragging)
    }
  }

  // The card the pointer is above: the first one whose midpoint is below it.
  itemAfter(y) {
    return this.itemTargets
      .filter(item => item !== this.dragging)
      .find(item => {
        const box = item.getBoundingClientRect()
        return y < box.top + box.height / 2
      })
  }

  end() {
    if (!this.dragging) return
    this.dragging.classList.remove("is-dragging")
    this.dragging = null
    this.disarm()
    this.save()
  }

  drop(event) {
    event.preventDefault() // stop the browser navigating to the dragged data
  }

  save() {
    if (!this.hasUrlValue) return
    const ids = this.itemTargets.map(item => item.dataset.ruleId)

    fetch(this.urlValue, {
      method: "PATCH",
      headers: {
        "Content-Type": "application/json",
        "Accept": "application/json",
        "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content
      },
      body: JSON.stringify({ ids })
    }).catch(() => {
      // The order is already correct on screen; it just didn't stick. A reload
      // shows the truth rather than us pretending it saved.
    })
  }
}
