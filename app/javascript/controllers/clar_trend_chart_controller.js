import { Controller } from "@hotwired/stimulus"
import { Chart, registerables } from "chart.js"

Chart.register(...registerables)

// Workshop Reporting (Task 7.1) trend card: a Clar-styled line/area chart —
// indigo line, ~8% fill, dashed crosshair via tooltip mode "index", thinned
// x-axis labels. Data arrives as JSON on data-clar-trend-chart-points-value,
// one point per { label, full, sp, bugs_created, bugs_fixed } (see
// WorkshopReport#trend).
//
// By default only the "sp" series is plotted (Story points delivered over
// time — Reporting's usage, unchanged). Bug Reporting (Task 8.2) passes an
// explicit `series` value — an array of { key, label, color, fill } — to
// plot bugs_created/bugs_fixed as two lines instead (created filled, per the
// brief); this is a data-driven extension, not a fork, so both pages share
// one controller/chart config.
const DEFAULT_SERIES = [
  { key: "sp", label: "Story points", color: "#4f46e5", fill: true },
]

export default class extends Controller {
  static targets = ["canvas"]
  static values = { points: Array, series: Array }

  connect() {
    const points = this.pointsValue || []
    const series = this.seriesValue?.length ? this.seriesValue : DEFAULT_SERIES
    const ctx = this.canvasTarget.getContext("2d")

    const step = Math.max(1, Math.ceil(points.length / 12))

    this.chart = new Chart(ctx, {
      type: "line",
      data: {
        labels: points.map((p) => p.label),
        datasets: series.map((s) => ({
          label: s.label,
          data: points.map((p) => p[s.key]),
          borderColor: s.color,
          backgroundColor: this.withAlpha(s.color, 0.08),
          borderWidth: 2.5,
          fill: !!s.fill,
          tension: 0.35,
          pointRadius: 0,
          pointHoverRadius: 4,
          pointBackgroundColor: s.color,
        })),
      },
      options: {
        responsive: true,
        maintainAspectRatio: false,
        interaction: { mode: "index", intersect: false },
        plugins: {
          legend: { display: false },
          tooltip: {
            mode: "index",
            intersect: false,
            callbacks: {
              title: (items) => points[items[0].dataIndex]?.full || "",
              label: (item) => `${item.dataset.label}: ${item.parsed.y}`,
            },
          },
        },
        scales: {
          x: {
            grid: { display: false },
            ticks: {
              autoSkip: false,
              callback: (_value, index) => (index % step === 0 || index === points.length - 1 ? points[index].label : ""),
              maxRotation: 0,
              color: "#9aa3af",
              font: { size: 10 },
            },
          },
          y: {
            beginAtZero: true,
            grid: { color: "#e6e8ec" },
            ticks: { color: "#9aa3af", font: { size: 10 } },
          },
        },
      },
    })
  }

  disconnect() {
    if (this.chart) this.chart.destroy()
  }

  withAlpha(hex, alpha) {
    const value = hex.replace("#", "")
    const r = parseInt(value.substring(0, 2), 16)
    const g = parseInt(value.substring(2, 4), 16)
    const b = parseInt(value.substring(4, 6), 16)
    return `rgba(${r}, ${g}, ${b}, ${alpha})`
  }
}
