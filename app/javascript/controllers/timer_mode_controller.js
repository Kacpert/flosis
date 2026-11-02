import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["timerMode", "manualMode"]

  connect() {
    // Restore last mode
    if (localStorage.getItem("gold_timer_mode") === "manual") {
      this.timerModeTarget.classList.add("hidden")
      this.manualModeTarget.classList.remove("hidden")
    }

    // Restore last project selection for both forms
    const lastProjectId = localStorage.getItem("gold_last_project_id")
    if (lastProjectId) {
      this.element.querySelectorAll("select[name*='project_id']").forEach(select => {
        const option = select.querySelector(`option[value="${lastProjectId}"]`)
        if (option) {
          select.value = lastProjectId
          select.dispatchEvent(new Event("change", { bubbles: true }))
        }
      })
    }
  }

  toggle() {
    this.timerModeTarget.classList.toggle("hidden")
    this.manualModeTarget.classList.toggle("hidden")

    const isManual = !this.manualModeTarget.classList.contains("hidden")
    localStorage.setItem("gold_timer_mode", isManual ? "manual" : "timer")
  }
}
