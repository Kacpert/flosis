import { Controller } from "@hotwired/stimulus"

// Collapsible Workshop sidebar. Flips data-collapsed on the nav element and
// persists the choice; the collapsed CSS (hiding labels etc.) already lives
// in the clar-* design system from Task 1.1. Its arrow turns to point the way
// the menu will go, and the button says so.
export default class extends Controller {
  static targets = ["toggle"]

  connect() {
    this.applyCollapsed(this.currentCollapsed)
  }

  toggle() {
    const next = !this.isCollapsed
    localStorage.setItem("clarSidebarCollapsed", String(next))
    this.applyCollapsed(next)
  }

  applyCollapsed(collapsed) {
    this.element.setAttribute("data-collapsed", String(collapsed))
    if (this.hasToggleTarget) this.toggleTarget.title = collapsed ? "Expand menu" : "Collapse menu"
  }

  get isCollapsed() {
    return this.element.getAttribute("data-collapsed") === "true"
  }

  get currentCollapsed() {
    return localStorage.getItem("clarSidebarCollapsed") === "true"
  }
}
