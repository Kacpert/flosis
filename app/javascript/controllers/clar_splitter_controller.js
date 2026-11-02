import { Controller } from "@hotwired/stimulus"

// Drag the divider between the chat and the document panel to give either side
// more room — a Jira description with wide tables needs more than the fixed
// 460px the panel used to be locked at.
//
// The width lives in --clar-doc-width on the grid, which clar_focus_controller
// also reads, so full-screen and resize don't fight over the same style. It is
// remembered per browser: coming back to a ticket keeps the width you chose.
const STORAGE_KEY = "clar_document_panel_width"
const MIN_WIDTH = 320
// Always leave the chat a usable column, however far you drag.
const MIN_CHAT_WIDTH = 360
const DEFAULT_WIDTH = 460

export default class extends Controller {
  static targets = ["grid"]

  connect() {
    this.drag = this.drag.bind(this)
    this.stop = this.stop.bind(this)
    this.applyWidth(this.storedWidth())
  }

  disconnect() {
    this.stop()
  }

  start(event) {
    event.preventDefault() // no text selection while dragging
    this.dragging = true
    document.addEventListener("mousemove", this.drag)
    document.addEventListener("mouseup", this.stop)
    document.body.style.cursor = "col-resize"
    document.body.style.userSelect = "none"
  }

  drag(event) {
    if (!this.dragging) return
    const rect = this.element.getBoundingClientRect()
    this.applyWidth(rect.right - event.clientX)
  }

  stop() {
    if (!this.dragging) return
    this.dragging = false
    document.removeEventListener("mousemove", this.drag)
    document.removeEventListener("mouseup", this.stop)
    document.body.style.cursor = ""
    document.body.style.userSelect = ""
    this.remember(this.width)
  }

  // Double-click the handle to go back to the standard width.
  reset() {
    this.applyWidth(DEFAULT_WIDTH)
    this.remember(DEFAULT_WIDTH)
  }

  applyWidth(width) {
    const target = this.hasGridTarget ? this.gridTarget : this.element
    this.width = this.clamp(width)
    target.style.setProperty("--clar-doc-width", `${this.width}px`)
  }

  clamp(width) {
    const available = this.element.getBoundingClientRect().width
    // On a narrow window the two minimums can't both hold; the chat wins,
    // because a panel you can't type in is worse than a narrow document.
    const max = Math.max(MIN_WIDTH, available - MIN_CHAT_WIDTH)
    return Math.round(Math.min(Math.max(width || DEFAULT_WIDTH, MIN_WIDTH), max))
  }

  storedWidth() {
    try {
      return parseInt(localStorage.getItem(STORAGE_KEY), 10) || DEFAULT_WIDTH
    } catch (e) {
      return DEFAULT_WIDTH // private window / storage blocked
    }
  }

  remember(width) {
    try {
      localStorage.setItem(STORAGE_KEY, String(width))
    } catch (e) {
      // Not being able to remember the width is not worth breaking the drag.
    }
  }
}
