import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["display", "form"]

  edit() {
    this.displayTarget.classList.add("hidden")
    this.formTarget.classList.remove("hidden")
    // The edit row can be taller than one line — .is-editing keeps the card's
    // checkbox aligned with the first line instead of the middle of the block.
    this.element.classList.add("is-editing")
    // Focus the first input
    const firstInput = this.formTarget.querySelector("input[type='text'], select")
    if (firstInput) firstInput.focus()
  }

  cancel() {
    this.formTarget.classList.add("hidden")
    this.displayTarget.classList.remove("hidden")
    this.element.classList.remove("is-editing")
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
