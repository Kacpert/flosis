import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["display", "form"]

  edit() {
    this.displayTarget.classList.add("hidden")
    this.formTarget.classList.remove("hidden")
    // Focus the first input
    const firstInput = this.formTarget.querySelector("input[type='text'], select")
    if (firstInput) firstInput.focus()
  }

  cancel() {
    this.formTarget.classList.add("hidden")
    this.displayTarget.classList.remove("hidden")
  }

  submitOnEnter(event) {
    if (event.key === "Enter") {
      event.preventDefault()
      this.formTarget.querySelector("form")?.requestSubmit()
    }
  }

  submitOnEscape(event) {
    if (event.key === "Escape") {
      this.cancel()
    }
  }
}
