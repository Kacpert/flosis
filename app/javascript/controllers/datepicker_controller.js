import { Controller } from "@hotwired/stimulus"
import flatpickr from "flatpickr"

export default class extends Controller {
  static values = {
    enableTime: { type: Boolean, default: false },
    dateFormat: { type: String, default: "Y-m-d" },
    firstDayOfWeek: { type: Number, default: 1 },
    triggerButton: { type: String, default: "" }
  }

  connect() {
    const options = {
      enableTime: this.enableTimeValue,
      dateFormat: this.enableTimeValue ? "Y-m-d H:i" : this.dateFormatValue,
      time_24hr: true,
      allowInput: !this.triggerButtonValue,
      locale: { firstDayOfWeek: this.firstDayOfWeekValue },
      onChange: (_selectedDates, dateStr) => {
        this.dispatch("change", { detail: { date: dateStr } })
      }
    }

    if (this.triggerButtonValue) {
      this.triggerEl = document.querySelector(this.triggerButtonValue)
      if (this.triggerEl) {
        options.positionElement = this.triggerEl
      }
    }

    this.picker = flatpickr(this.element, options)

    if (this.triggerEl) {
      this.openHandler = (e) => { e.preventDefault(); this.picker.open() }
      this.triggerEl.addEventListener("click", this.openHandler)
    }
  }

  disconnect() {
    if (this.triggerEl && this.openHandler) {
      this.triggerEl.removeEventListener("click", this.openHandler)
    }
    if (this.picker) {
      this.picker.destroy()
    }
  }
}
