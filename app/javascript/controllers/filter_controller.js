import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  submit() {
    // Update URL with current filter params for shareability
    const formData = new FormData(this.element)
    const params = new URLSearchParams(formData)
    const url = `${this.element.action}?${params.toString()}`
    history.replaceState(null, "", url)

    this.element.requestSubmit()
  }
}
