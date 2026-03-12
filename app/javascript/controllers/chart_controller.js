import { Controller } from "@hotwired/stimulus"
import { Chart, registerables } from "chart.js"

Chart.register(...registerables)

export default class extends Controller {
  static values = {
    type: String,
    data: Object,
    options: { type: Object, default: {} }
  }

  connect() {
    const ctx = this.element.getContext("2d")

    const defaultOptions = {
      responsive: true,
      maintainAspectRatio: false,
      interaction: {
        mode: "nearest",
        intersect: true
      },
      plugins: {
        legend: {
          position: this.typeValue === "pie" ? "right" : "top"
        },
        tooltip: {
          enabled: true,
          callbacks: {
            label: (context) => {
              const label = context.label || context.dataset.label || ""
              const value = context.parsed.y !== undefined ? context.parsed.y : context.parsed
              return `${label}: ${value}h`
            }
          }
        }
      }
    }

    this.chart = new Chart(ctx, {
      type: this.typeValue,
      data: this.dataValue,
      options: { ...defaultOptions, ...this.optionsValue }
    })
  }

  disconnect() {
    if (this.chart) {
      this.chart.destroy()
    }
  }
}
