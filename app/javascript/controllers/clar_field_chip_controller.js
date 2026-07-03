import { Controller } from "@hotwired/stimulus"

// Configuration -> AI tab (Task 9.1): "free-add" input for a custom Jira
// estimation field name. Pressing Enter (or clicking Add) appends a checked
// checkbox chip for the typed value alongside the fixed EST_FIELD_OPTS chips,
// then clears the input. Submission still goes through the normal form (no
// turbo/fetch here) — this only builds the extra checkbox client-side.
export default class extends Controller {
  static targets = ["list", "input"]

  add(event) {
    event.preventDefault()
    const value = this.inputTarget.value.trim()
    if (!value) return

    const exists = Array.from(this.listTarget.querySelectorAll("input[type=checkbox]"))
      .some((box) => box.value.toLowerCase() === value.toLowerCase())
    if (!exists) {
      const label = document.createElement("label")
      label.className = "clar-chip clar-chip-active cursor-pointer has-[:checked]:clar-chip-active"
      label.innerHTML = `
        <input type="checkbox" name="workspace[estimation_field_names][]" value="${this.#escape(value)}" checked class="sr-only">
        <span>${this.#escape(value)}</span>
      `
      this.listTarget.appendChild(label)
    }

    this.inputTarget.value = ""
  }

  #escape(value) {
    const div = document.createElement("div")
    div.textContent = value
    return div.innerHTML
  }
}
