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
//
// `mode` ("line" | "bar") switches the same data between the area/line
// rendering and grouped bars — the chart-type toggle in the card header.
const DEFAULT_SERIES = [
  { key: "sp", label: "Story points", color: "#4f46e5", fill: true },
]

export default class extends Controller {
  static targets = ["canvas"]
  static values = { points: Array, series: Array, mode: String }

  connect() {
    const points = this.pointsValue || []
    const series = this.seriesValue?.length ? this.seriesValue : DEFAULT_SERIES
    const bar = this.modeValue === "bar"
    const ctx = this.canvasTarget.getContext("2d")

    const step = Math.max(1, Math.ceil(points.length / 12))
    // Grid/tick colours come from the live theme (the .clar-app custom
    // properties) — <canvas> can't resolve CSS vars itself, so read them once
    // at connect and hand Chart.js the concrete values.
    const grid = this.cssVar("--border", "#e6e8ec")
    const faint = this.cssVar("--faint", "#9aa3af")

    this.chart = new Chart(ctx, {
      type: bar ? "bar" : "line",
      data: {
        labels: points.map((p) => p.label),
        datasets: series.map((s) => ({
          label: s.label,
          data: points.map((p) => p[s.key]),
          borderColor: s.color,
          backgroundColor: bar ? s.color : this.withAlpha(s.color, 0.08),
          borderWidth: bar ? 0 : 2.5,
          borderRadius: bar ? 2 : 0,
          maxBarThickness: 26,
          fill: bar ? true : !!s.fill,
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
              color: faint,
              font: { size: 10 },
            },
          },
          y: {
            beginAtZero: true,
            grid: { color: grid },
            ticks: { color: faint, font: { size: 10 } },
          },
        },
      },
    })
  }

  disconnect() {
    if (this.chart) this.chart.destroy()
  }

  cssVar(name, fallback) {
    const value = getComputedStyle(this.element).getPropertyValue(name).trim()
    return value || fallback
  }

  withAlpha(hex, alpha) {
    const value = hex.replace("#", "")
    const r = parseInt(value.substring(0, 2), 16)
    const g = parseInt(value.substring(2, 4), 16)
    const b = parseInt(value.substring(4, 6), 16)
    return `rgba(${r}, ${g}, ${b}, ${alpha})`
  }
}
