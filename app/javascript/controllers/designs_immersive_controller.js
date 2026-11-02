import { Controller } from "@hotwired/stimulus"

// "Hide menus" on the Designs module (Workshop Designs v2): the top bar and
// the sidebar step aside, and two tabs on the edges peek them back. On by
// default, as the design has it, and remembered in this browser.
export default class extends Controller {
  static targets = ["switch"]

  connect() {
    this.app = document.querySelector(".clar-app")
    this.apply(this.stored())
  }

  disconnect() {
    this.app?.classList.remove("designs-immersive", "designs-peek-top", "designs-peek-nav")
  }

  toggle() {
    const on = !this.app.classList.contains("designs-immersive")
    try { localStorage.setItem("designs.hideMenus", on ? "1" : "0") } catch {}
    this.apply(on)
  }

  peekTop(event) {
    const shown = this.app.classList.toggle("designs-peek-top")
    if (event?.currentTarget) event.currentTarget.title = shown ? "Hide top bar" : "Show top bar"
  }

  // The panel's menu button: peeks the sidebar while menus are hidden, and
  // collapses it otherwise.
  peekNav(event) {
    if (this.app.classList.contains("designs-immersive")) {
      const shown = this.app.classList.toggle("designs-peek-nav")
      if (event?.currentTarget) event.currentTarget.title = shown ? "Hide menu" : "Show menu"
    } else {
      document.querySelector('[data-action="click->clar-sidebar#toggle"]')?.click()
    }
  }

  apply(on) {
    this.app?.classList.toggle("designs-immersive", on)
    this.app?.classList.remove("designs-peek-top", "designs-peek-nav")
    this.switchTargets.forEach((element) => element.setAttribute("aria-checked", on ? "true" : "false"))
  }

  stored() {
    try { return localStorage.getItem("designs.hideMenus") !== "0" } catch { return true }
  }
}
