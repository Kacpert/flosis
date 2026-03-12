import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["checkbox", "label", "hiddenInputs"]

  update() {
    const checked = this.checkboxTargets.filter(cb => cb.checked)
    this.labelTarget.textContent = checked.length > 0 ? `${checked.length} tags` : "Tags"
  }
}
