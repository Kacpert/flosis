import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["timerMode", "manualMode"]

  toggle() {
    this.timerModeTarget.classList.toggle("hidden")
    this.manualModeTarget.classList.toggle("hidden")
  }
}
