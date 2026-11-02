import { Controller } from "@hotwired/stimulus"

// Theme toggle for the Clar workshop shell. Flips data-clar-theme on the
// .clar-app root (this.element), persists the choice, and swaps the
// sun/moon icon targets in the top bar toggle button.
export default class extends Controller {
  static targets = ["sunIcon", "moonIcon"]

  connect() {
    this.applyTheme(this.currentTheme)
  }

  toggle() {
    const next = this.currentTheme === "dark" ? "light" : "dark"
    localStorage.setItem("clarTheme", next)
    this.applyTheme(next)
  }

  applyTheme(theme) {
    this.element.setAttribute("data-clar-theme", theme)
    this.updateIcons(theme)
  }

  updateIcons(theme) {
    const dark = theme === "dark"
    if (this.hasSunIconTarget) this.sunIconTarget.classList.toggle("hidden", dark)
    if (this.hasMoonIconTarget) this.moonIconTarget.classList.toggle("hidden", !dark)
  }

  get currentTheme() {
    const saved = localStorage.getItem("clarTheme")
    return saved === "dark" || saved === "light" ? saved : (this.element.getAttribute("data-clar-theme") || "light")
  }
}
