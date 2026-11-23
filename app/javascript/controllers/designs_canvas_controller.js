import { Controller } from "@hotwired/stimulus"

// The Designs canvas (Workshop Designs v2): the published screen, 1160 × 860
// and scaled to fit, and what the screen tells it. The preview is sandboxed on
// an origin of its own, so it speaks only through postMessage (runtime/
// flosis.js): which screen it shows ("AI sees …", and what the next message
// is about), and a link to a screen that is not designed (a toast, as the
// design has it). View as and the modes go on from the screen it shows, which
// a link inside it may have changed (Kacper, 2026-11-22).
//
// The frame's edges resize it (Kacper, 2026-11-19): a side drags its width,
// both sides at once so that it stays centered, the bottom its height, a
// corner both; a double-click on an edge puts back the standard size. Another
// size shows in the frame's bar and is remembered in this browser; a frame
// wider than the canvas is scaled to fit, as the standard one is.
//
// A screen's states (Kacper, 2026-11-22: a page's states live in its file,
// switched by the hash): the screen tells them, the frame's bar picks one, the
// next message names it, and the canvas puts a screen back in the state it was
// left in when the page reloads (after a turn, say), for this tab's session.
const STANDARD = { width: 1160, height: 860 }
const STORAGE_KEY = "designs.frameSize"
const MIN_WIDTH = 320
const MIN_HEIGHT = 320
// The frame's border, a pixel on each side.
const BORDER = 2
// A click that wobbles a pixel or two is not a drag.
const DRAG_THRESHOLD = 3
const STATES_KEY = "designs.screenStates"
const DEFAULT_STATE = "default"

export default class extends Controller {
  static targets = ["box", "wrap", "frame", "size", "sees", "context", "screen", "path", "viewAs", "mode", "states", "stateSelect", "state"]
  static values = { contexts: Object, width: { type: Number, default: STANDARD.width }, height: { type: Number, default: STANDARD.height } }

  connect() {
    this.firstScreen = true
    // The screen the preview shows, and its state, for Copy link.
    this.shown = null
    this.onMessage = this.message.bind(this)
    window.addEventListener("message", this.onMessage)
    this.sizeMove = this.sizeMove.bind(this)
    this.sizeEnd = this.sizeEnd.bind(this)
    const stored = this.storedSize()
    if (stored) {
      this.widthValue = stored.width
      this.heightValue = stored.height
    }
    this.resize = this.fit.bind(this)
    this.observer = new ResizeObserver(this.resize)
    if (this.hasWrapTarget) this.observer.observe(this.wrapTarget)
    this.applySize()
  }

  disconnect() {
    window.removeEventListener("message", this.onMessage)
    this.observer?.disconnect()
    this.sizeEnd()
  }

  fit() {
    if (!this.hasWrapTarget || !this.hasFrameTarget) return
    const scale = this.scale()
    this.frameTarget.style.transform = `scale(${scale})`
    this.wrapTarget.style.height = `${Math.ceil(this.heightValue * scale)}px`
  }

  scale() {
    return Math.min(1, this.wrapTarget.clientWidth / this.widthValue)
  }

  // The frame at the size chosen: the screen at that size, the box no wider
  // than it and its border, and the size in the bar unless it is the standard.
  applySize() {
    if (!this.hasFrameTarget) return
    this.frameTarget.style.width = `${this.widthValue}px`
    this.frameTarget.style.height = `${this.heightValue}px`
    if (this.hasBoxTarget) this.boxTarget.style.maxWidth = `${this.widthValue + BORDER}px`
    const standard = this.widthValue === STANDARD.width && this.heightValue === STANDARD.height
    this.sizeTargets.forEach((element) => {
      element.textContent = `${this.widthValue} × ${this.heightValue}`
      element.hidden = standard && !this.sizing
    })
    this.fit()
  }

  sizeStart(event) {
    if (event.button !== 0 || !this.hasBoxTarget || !this.hasWrapTarget) return
    event.preventDefault() // no text selection while dragging
    const handle = event.currentTarget
    const area = this.boxTarget.parentElement
    this.sizing = { edge: handle.dataset.edge, handle, x: event.clientX, y: event.clientY, moved: false,
                    area, padding: parseFloat(getComputedStyle(area).paddingBottom) || 0, wrapHeight: this.wrapTarget.offsetHeight }
    // The pointer is captured, so passing over the iframe never drops the drag.
    try { handle.setPointerCapture(event.pointerId) } catch {}
    document.addEventListener("pointermove", this.sizeMove)
    document.addEventListener("pointerup", this.sizeEnd)
    document.addEventListener("pointercancel", this.sizeEnd)
    handle.classList.add("designs-frame-edge-active")
    this.element.style.setProperty("--designs-frame-cursor", getComputedStyle(handle).cursor)
    this.element.classList.add("designs-frame-sizing")
  }

  sizeMove(event) {
    const sizing = this.sizing
    if (!sizing) return
    if (!sizing.moved && Math.abs(event.clientX - sizing.x) < DRAG_THRESHOLD && Math.abs(event.clientY - sizing.y) < DRAG_THRESHOLD) return
    sizing.moved = true
    if (sizing.edge.includes("x")) {
      // Both sides move: the frame is twice as wide as the pointer is far
      // from its middle, which stays where it is.
      const box = this.boxTarget.getBoundingClientRect()
      const width = 2 * Math.abs(event.clientX - (box.left + box.width / 2)) - BORDER
      this.widthValue = Math.round(Math.min(Math.max(width, MIN_WIDTH), Math.max(this.room(), MIN_WIDTH)))
    }
    if (sizing.edge.includes("y")) {
      const top = this.wrapTarget.getBoundingClientRect().top
      const scale = this.scale()
      this.heightValue = Math.round(Math.max((event.clientY - top) / scale, MIN_HEIGHT))
      // A shorter frame would let a canvas scrolled to its end scroll back,
      // moving the frame under the pointer: what it gives up is kept as
      // padding until the drag ends, so the edge stays with the pointer.
      const shorter = Math.max(0, sizing.wrapHeight - Math.ceil(this.heightValue * scale))
      sizing.area.style.paddingBottom = `${sizing.padding + shorter}px`
    }
    this.applySize()
  }

  sizeEnd() {
    const sizing = this.sizing
    if (!sizing) return
    this.sizing = null
    document.removeEventListener("pointermove", this.sizeMove)
    document.removeEventListener("pointerup", this.sizeEnd)
    document.removeEventListener("pointercancel", this.sizeEnd)
    sizing.handle.classList.remove("designs-frame-edge-active")
    sizing.area.style.removeProperty("padding-bottom")
    this.element.classList.remove("designs-frame-sizing")
    this.element.style.removeProperty("--designs-frame-cursor")
    if (sizing.moved) this.rememberSize()
    this.applySize()
  }

  sizeReset() {
    this.widthValue = STANDARD.width
    this.heightValue = STANDARD.height
    try { localStorage.removeItem(STORAGE_KEY) } catch {}
    this.applySize()
  }

  // The widest the frame can be dragged: the canvas inside its padding.
  room() {
    const area = this.boxTarget.parentElement
    const style = getComputedStyle(area)
    return area.clientWidth - parseFloat(style.paddingLeft) - parseFloat(style.paddingRight) - BORDER
  }

  // Its own name: a second remember() (a screen's state, 2026-11-22) replaced
  // this one, and the size dragged was never kept (Kacper, 2026-11-23).
  rememberSize() {
    try {
      if (this.widthValue === STANDARD.width && this.heightValue === STANDARD.height) {
        localStorage.removeItem(STORAGE_KEY)
      } else {
        localStorage.setItem(STORAGE_KEY, JSON.stringify({ width: this.widthValue, height: this.heightValue }))
      }
    } catch {}
  }

  storedSize() {
    try {
      const size = JSON.parse(localStorage.getItem(STORAGE_KEY))
      if (Number.isFinite(size?.width) && Number.isFinite(size?.height)) {
        return { width: Math.max(Math.round(size.width), MIN_WIDTH), height: Math.max(Math.round(size.height), MIN_HEIGHT) }
      }
    } catch {}
    return null
  }

  message(event) {
    if (!this.hasFrameTarget || event.source !== this.frameTarget.contentWindow) return
    const data = event.data || {}
    const contextName = (id) => this.contextsValue[id] || id
    if (data.type === "flosis:screen") {
      // Only the screen the page opened with is put back in its state: a
      // link clicked inside the preview goes where it says.
      this.seen = { label: `${contextName(data.context)} › ${data.title || data.screen}`, screen: data.screen, restore: this.firstScreen }
      this.shown = { context: data.context, screen: data.screen, state: null }
      this.firstScreen = false
      this.seesTargets.forEach((element) => { element.textContent = `AI sees ${this.seen.label}` })
      this.contextTargets.forEach((element) => { element.value = data.context })
      this.screenTargets.forEach((element) => { element.value = data.screen })
      this.stateTargets.forEach((element) => { element.value = "" })
      this.pathTargets.forEach((element) => { element.textContent = `designs/${data.context}/${data.screen}.html` })
      if (this.hasStatesTarget) this.statesTarget.hidden = true
      if (data.context && data.screen) this.follow(data.context, data.screen)
    } else if (data.type === "flosis:states") {
      this.showStates(data)
    } else if (data.type === "flosis:missing") {
      const label = String(data.label || "This page")
      const message = data.reason === "other-context"
        ? `${label} is not available as ${contextName(data.context)}`
        : `${label} is not designed yet. Start a thread to add it.`
      window.dispatchEvent(new CustomEvent("clar:toast", { detail: { message } }))
    }
  }

  // The screen's states in the frame's bar, the one shown picked; the AI is
  // told of a state other than the page as it opens. A screen the page opened
  // with as it opens is put back in the state it was left in.
  showStates(data) {
    if (!this.seen) return
    const states = (Array.isArray(data.states) ? data.states : []).filter((state) => typeof state?.key === "string")
    const current = states.find((state) => state.key === data.state)
    if (!current) return
    if (this.seen.restore) {
      this.seen.restore = false
      const remembered = this.rememberedState(this.seen.screen)
      if (current.key === DEFAULT_STATE && remembered && states.some((state) => state.key === remembered)) {
        this.setState(remembered)
        return
      }
    }
    this.rememberState(this.seen.screen, current.key)
    if (this.hasStatesTarget) {
      this.statesTarget.hidden = states.length < 2
      this.stateSelectTarget.replaceChildren(...states.map((state) => new Option(String(state.label || state.key), state.key, false, state === current)))
    }
    const named = current.key !== DEFAULT_STATE
    if (this.shown) this.shown.state = named ? current.key : null
    this.stateTargets.forEach((element) => { element.value = named ? current.key : "" })
    this.seesTargets.forEach((element) => { element.textContent = `AI sees ${this.seen.label}${named ? ` › ${current.label || current.key}` : ""}` })
  }

  pickState(event) {
    this.setState(event.target.value)
  }

  setState(state) {
    this.frameTarget.contentWindow?.postMessage({ type: "flosis:set-state", state }, "*")
  }

  rememberedState(screen) {
    try {
      return JSON.parse(sessionStorage.getItem(STATES_KEY))?.[screen] || null
    } catch {
      return null
    }
  }

  rememberState(screen, state) {
    try {
      const states = JSON.parse(sessionStorage.getItem(STATES_KEY)) || {}
      if (state === DEFAULT_STATE) delete states[screen]
      else states[screen] = state
      sessionStorage.setItem(STATES_KEY, JSON.stringify(states))
    } catch {}
  }

  // A role opens at this screen, or at its closest when it has none (the
  // page decides); a mode shows this screen on its copy.
  follow(context, screen) {
    const go = (link, params) => {
      const url = new URL(link.getAttribute("href"), window.location.href)
      Object.entries(params).forEach(([key, value]) => url.searchParams.set(key, value))
      link.setAttribute("href", `${url.pathname}${url.search}`)
    }
    this.viewAsTargets.forEach((link) => {
      go(link, { screen })
      link.classList.toggle("clar-seg-item-active", link.dataset.context === context)
    })
    this.modeTargets.forEach((link) => go(link, { ctx: context, screen }))
  }

  // Copy link (Kacper, 2026-11-23): the short link to the screen shown, in its
  // state, to send someone. Before the preview has said which screen, the one
  // the page opened with.
  async copyLink(event) {
    const { template, context, screen } = event.params
    const shown = this.shown || { context, screen, state: null }
    if (!template || !shown.context || !shown.screen) return
    let link = template.replace("{context}", encodeURIComponent(shown.context)).replace("{screen}", encodeURIComponent(shown.screen))
    if (shown.state) link += `#${encodeURIComponent(shown.state)}`
    let message
    try {
      await navigator.clipboard.writeText(link)
      message = `Link copied · ${link.replace(/^https?:\/\//, "")}`
    } catch {
      message = `Copy this link: ${link}`
    }
    window.dispatchEvent(new CustomEvent("clar:toast", { detail: { message } }))
  }

  toast(event) {
    const message = event.params.message
    if (message) window.dispatchEvent(new CustomEvent("clar:toast", { detail: { message } }))
  }
}
