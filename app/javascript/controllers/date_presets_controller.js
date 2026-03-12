import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  apply(event) {
    const from = event.currentTarget.dataset.from
    const to = event.currentTarget.dataset.to
    const form = this.element.closest("form")

    if (form) {
      const fromInput = form.querySelector("input[name='from']")
      const toInput = form.querySelector("input[name='to']")
      if (fromInput) fromInput.value = from
      if (toInput) toInput.value = to
      form.requestSubmit()
    }
  }
}
