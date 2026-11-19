import { Controller } from "@hotwired/stimulus"

// A design thread's composer: Enter sends, Shift+Enter breaks the line. What
// is typed is kept in this tab (sessionStorage, per thread) until it is sent:
// moving to another screen reloads the page, and the message went with it
// (Kacper, 2026-11-19).
export default class extends Controller {
  static values = { draftKey: String }

  connect() {
    this.save = this.save.bind(this)
    this.clear = this.clear.bind(this)
    this.restore()
    this.element.addEventListener("input", this.save)
    this.element.form?.addEventListener("submit", this.clear)
  }

  disconnect() {
    this.element.removeEventListener("input", this.save)
    this.element.form?.removeEventListener("submit", this.clear)
  }

  key(event) {
    if (event.key !== "Enter" || event.shiftKey || event.isComposing) return
    event.preventDefault()
    if (this.element.value.trim()) this.element.form.requestSubmit()
  }

  restore() {
    if (!this.draftKeyValue || this.element.value) return
    try {
      const draft = sessionStorage.getItem(this.draftKeyValue)
      if (draft) this.element.value = draft
    } catch {}
  }

  save() {
    if (!this.draftKeyValue) return
    try {
      if (this.element.value) sessionStorage.setItem(this.draftKeyValue, this.element.value)
      else sessionStorage.removeItem(this.draftKeyValue)
    } catch {}
  }

  clear() {
    if (!this.draftKeyValue) return
    try { sessionStorage.removeItem(this.draftKeyValue) } catch {}
  }
}
