import { Controller } from "@hotwired/stimulus"

// Drag the edge of the Designs module's left column to give the threads or
// the conversation more room, or the canvas; double-click the edge to go back
// to the standard width, which follows the window (clamp(280px, 26%, 340px)).
//
// The width lives in --designs-list-width on the module's grid and is
// remembered in this browser. The pointer is captured while dragging, so
// passing over the canvas's iframe never drops the drag.
const STORAGE_KEY = "designs.listWidth"
const MIN_WIDTH = 280
// Always leave the canvas a usable column, however far the edge goes.
const MIN_CANVAS_WIDTH = 480
// A click that wobbles a pixel or two is not a drag.
const DRAG_THRESHOLD = 3

export default class extends Controller {
  connect() {
    this.drag = this.drag.bind(this)
    this.stop = this.stop.bind(this)
    // The grid narrows with the window and when the sidebar comes back: the
    // column gives way, and the width chosen returns when there is room.
    this.observer = new ResizeObserver(() => this.apply(this.stored()))
    this.observer.observe(this.element)
  }

  disconnect() {
    this.stop()
    this.observer.disconnect()
  }

  start(event) {
    if (event.button !== 0) return
    event.preventDefault() // no text selection while dragging
    this.handle = event.currentTarget
    this.startX = event.clientX
    this.moved = false
    try { this.handle.setPointerCapture(event.pointerId) } catch {}
    document.addEventListener("pointermove", this.drag)
    document.addEventListener("pointerup", this.stop)
    document.addEventListener("pointercancel", this.stop)
    this.element.classList.add("designs-resizing")
  }

  drag(event) {
    if (!this.handle) return
    if (!this.moved && Math.abs(event.clientX - this.startX) < DRAG_THRESHOLD) return
    this.moved = true
    this.apply(event.clientX - this.element.getBoundingClientRect().left)
  }

  stop() {
    if (!this.handle) return
    this.handle = null
    document.removeEventListener("pointermove", this.drag)
    document.removeEventListener("pointerup", this.stop)
    document.removeEventListener("pointercancel", this.stop)
    this.element.classList.remove("designs-resizing")
    if (this.moved) this.remember(this.width)
  }

  reset() {
    this.apply(null)
    try { localStorage.removeItem(STORAGE_KEY) } catch {}
  }

  apply(width) {
    this.width = width ? this.clamp(width) : null
    if (this.width) {
      this.element.style.setProperty("--designs-list-width", `${this.width}px`)
    } else {
      this.element.style.removeProperty("--designs-list-width")
    }
  }

  clamp(width) {
    const max = Math.max(MIN_WIDTH, this.element.getBoundingClientRect().width - MIN_CANVAS_WIDTH)
    return Math.round(Math.min(Math.max(width, MIN_WIDTH), max))
  }

  stored() {
    try { return parseInt(localStorage.getItem(STORAGE_KEY), 10) || null } catch { return null }
  }

  remember(width) {
    try { localStorage.setItem(STORAGE_KEY, String(width)) } catch {}
  }
}
