import { Controller } from "@hotwired/stimulus"
import flatpickr from "flatpickr"

export default class extends Controller {
  static values = {
    enableTime: { type: Boolean, default: false },
    dateFormat: { type: String, default: "Y-m-d" }
  }

  connect() {
    const options = {
      enableTime: this.enableTimeValue,
      dateFormat: this.enableTimeValue ? "Y-m-d H:i" : this.dateFormatValue,
      time_24hr: true,
      allowInput: true
    }

    this.picker = flatpickr(this.element, options)
  }

  disconnect() {
    if (this.picker) {
      this.picker.destroy()
    }
  }
}
