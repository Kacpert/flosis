import { Controller } from "@hotwired/stimulus"

// Collapsible Workshop sidebar. Flips data-collapsed on the nav element and
// persists the choice; the collapsed CSS (hiding labels etc.) already lives
// in the clar-* design system from Task 1.1.
export default class extends Controller {
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
  }

  get isCollapsed() {
    return this.element.getAttribute("data-collapsed") === "true"
  }

  get currentCollapsed() {
    return localStorage.getItem("clarSidebarCollapsed") === "true"
  }
}
