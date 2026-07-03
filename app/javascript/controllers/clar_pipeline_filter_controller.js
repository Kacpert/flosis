import { Controller } from "@hotwired/stimulus"

// Auto-submits the pipeline's GET search/sort form: sort <select> submits
// immediately on change, the search input submits debounced (300ms) so we
// don't fire a full-page GET on every keystroke. State lives in the URL,
// matching the rest of the app's filter patterns.
export default class extends Controller {
  static targets = ["search"]

  connect() {
    this.timeout = null
  }

  disconnect() {
    if (this.timeout) clearTimeout(this.timeout)
  }

  submit() {
    this.element.requestSubmit()
  }

  debouncedSubmit() {
    if (this.timeout) clearTimeout(this.timeout)
    this.timeout = setTimeout(() => this.submit(), 300)
  }
}
