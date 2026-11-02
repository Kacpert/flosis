import { Controller } from "@hotwired/stimulus"

// The Designs canvas (Workshop Designs v2): the published screen, 1160px wide
// and scaled to fit, and what the screen tells it. The preview is sandboxed on
// an origin of its own, so it speaks only through postMessage (runtime/
// flosis.js): which screen it shows ("AI sees …", and what the next message
// is about), and a link to a screen that is not designed (a toast, as the
// design has it).
export default class extends Controller {
  static targets = ["wrap", "frame", "sees", "context", "screen", "path"]
  static values = { contexts: Object, width: { type: Number, default: 1160 }, height: { type: Number, default: 860 } }

  connect() {
    this.onMessage = this.message.bind(this)
    window.addEventListener("message", this.onMessage)
    this.resize = this.fit.bind(this)
    this.observer = new ResizeObserver(this.resize)
    if (this.hasWrapTarget) this.observer.observe(this.wrapTarget)
    this.fit()
  }

  disconnect() {
    window.removeEventListener("message", this.onMessage)
    this.observer?.disconnect()
  }

  fit() {
    if (!this.hasWrapTarget || !this.hasFrameTarget) return
    const scale = Math.min(1, this.wrapTarget.clientWidth / this.widthValue)
    this.frameTarget.style.transform = `scale(${scale})`
    this.wrapTarget.style.height = `${Math.ceil(this.heightValue * scale)}px`
  }

  message(event) {
    if (!this.hasFrameTarget || event.source !== this.frameTarget.contentWindow) return
    const data = event.data || {}
    const contextName = (id) => this.contextsValue[id] || id
    if (data.type === "flosis:screen") {
      const label = `${contextName(data.context)} › ${data.title || data.screen}`
      this.seesTargets.forEach((element) => { element.textContent = `AI sees ${label}` })
      this.contextTargets.forEach((element) => { element.value = data.context })
      this.screenTargets.forEach((element) => { element.value = data.screen })
      this.pathTargets.forEach((element) => { element.textContent = `designs/${data.context}/${data.screen}.html` })
    } else if (data.type === "flosis:missing") {
      const label = String(data.label || "This page")
      const message = data.reason === "other-context"
        ? `${label} is not available as ${contextName(data.context)}`
        : `${label} is not designed yet. Start a thread to add it.`
      window.dispatchEvent(new CustomEvent("clar:toast", { detail: { message } }))
    }
  }

  toast(event) {
    const message = event.params.message
    if (message) window.dispatchEvent(new CustomEvent("clar:toast", { detail: { message } }))
  }
}
