import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["checkbox", "toolbar", "count", "idsContainer", "selectAll"]

  toggle() {
    this.updateToolbar()
  }

  toggleAll() {
    const checked = this.selectAllTarget.checked
    this.checkboxTargets.forEach(cb => cb.checked = checked)
    this.updateToolbar()
  }

  updateToolbar() {
    const checked = this.checkboxTargets.filter(cb => cb.checked)
    const count = checked.length

    if (count > 0) {
      this.toolbarTarget.classList.remove("hidden")
      this.toolbarTarget.classList.add("flex")
      this.countTarget.textContent = count
    } else {
      this.toolbarTarget.classList.add("hidden")
      this.toolbarTarget.classList.remove("flex")
    }

    // Update ALL hidden field containers (one per bulk form)
    this.idsContainerTargets.forEach(container => {
      container.innerHTML = ""
      checked.forEach(cb => {
        const input = document.createElement("input")
        input.type = "hidden"
        input.name = "time_entry_ids[]"
        input.value = cb.value
        container.appendChild(input)
      })
    })
  }
}
