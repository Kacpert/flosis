import { Controller } from "@hotwired/stimulus"

// A chat's input (a task's Briefing and Details chats): it grows with what is
// typed, up to twice its one-line height, so a long message is not read
// through a slit. Its top edge drags it taller still, and this browser
// remembers the height chosen; a double-click on the edge lets it size itself
// again.
const STORAGE_KEY = "clar.chatInputHeight"
// However tall it is dragged, the conversation keeps the rest of the window.
const MAX_SHARE = 0.6

export default class extends Controller {
  static targets = ["input"]

  connect() {
    this.drag = this.drag.bind(this)
    this.stop = this.stop.bind(this)
    this.base = this.inputTarget.offsetHeight
    this.fit()
  }

  disconnect() {
    this.stop()
  }

  // Grows with the text up to twice the one-line height, and never below the
  // height the edge was dragged to.
  fit() {
    const input = this.inputTarget
    input.style.height = "auto"
    const border = input.offsetHeight - input.clientHeight
    const grown = Math.min(input.scrollHeight + border, this.base * 2)
    input.style.height = `${Math.max(grown, this.stored() || 0, this.base)}px`
  }

  start(event) {
    if (event.button !== 0) return
    event.preventDefault() // no text selection while dragging
    this.startY = event.clientY
    this.startHeight = this.inputTarget.offsetHeight
    this.dragging = true
    try { event.currentTarget.setPointerCapture(event.pointerId) } catch {}
    document.addEventListener("pointermove", this.drag)
    document.addEventListener("pointerup", this.stop)
    document.addEventListener("pointercancel", this.stop)
    document.documentElement.classList.add("clar-composer-resizing")
  }

  drag(event) {
    if (!this.dragging) return
    this.height = this.clamp(this.startHeight + this.startY - event.clientY)
    this.inputTarget.style.height = `${this.height}px`
  }

  stop() {
    if (!this.dragging) return
    this.dragging = false
    document.removeEventListener("pointermove", this.drag)
    document.removeEventListener("pointerup", this.stop)
    document.removeEventListener("pointercancel", this.stop)
    document.documentElement.classList.remove("clar-composer-resizing")
    if (this.height) this.remember(this.height)
  }

  reset() {
    this.height = null
    try { localStorage.removeItem(STORAGE_KEY) } catch {}
    this.fit()
  }

  clamp(height) {
    const max = Math.max(this.base, window.innerHeight * MAX_SHARE)
    return Math.round(Math.min(Math.max(height, this.base), max))
  }

  stored() {
    try { return parseInt(localStorage.getItem(STORAGE_KEY), 10) || null } catch { return null }
  }

  remember(height) {
    try { localStorage.setItem(STORAGE_KEY, String(height)) } catch {}
  }
}
