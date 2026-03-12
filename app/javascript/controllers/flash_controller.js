import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  connect() {
    this.timeout = setTimeout(() => {
      this.element.classList.add("opacity-0", "transition-opacity", "duration-500")
      setTimeout(() => this.element.remove(), 500)
    }, 4000)
  }

  disconnect() {
    if (this.timeout) clearTimeout(this.timeout)
  }
}
