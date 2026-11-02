import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["display", "weekDisplay", "progressBar", "progressText", "remainingText"]
  static values = {
    baseSeconds: Number,
    startedAt: String,
    weekBaseSeconds: Number,
    weeklyGoalSeconds: Number
  }

  connect() {
    if (this.startedAtValue) {
      this.startTime = new Date(this.startedAtValue)
      this.tick()
      this.interval = setInterval(() => this.tick(), 1000)
    }
  }

  disconnect() {
    if (this.interval) clearInterval(this.interval)
  }

  tick() {
    const elapsed = Math.floor((Date.now() - this.startTime.getTime()) / 1000)
    const totalSeconds = this.baseSecondsValue + elapsed

    if (this.hasDisplayTarget) {
      this.displayTarget.textContent = this.formatDuration(totalSeconds)
    }

    if (this.hasWeekDisplayTarget && this.hasWeekBaseSecondsValue) {
      const weekTotal = this.weekBaseSecondsValue + elapsed
      this.weekDisplayTarget.textContent = this.formatDuration(weekTotal)

      if (this.hasProgressBarTarget && this.weeklyGoalSecondsValue > 0) {
        const pct = Math.min(Math.round(weekTotal / this.weeklyGoalSecondsValue * 100), 100)
        this.progressBarTarget.style.width = `${pct}%`

        if (this.hasProgressTextTarget) {
          this.progressTextTarget.textContent = `${pct}% complete`
        }

        if (this.hasRemainingTextTarget) {
          const remaining = Math.max(this.weeklyGoalSecondsValue - weekTotal, 0)
          this.remainingTextTarget.textContent = `${this.formatDuration(remaining)} remaining`
        }
      }
    }
  }

  formatDuration(totalSeconds) {
    const hours = Math.floor(totalSeconds / 3600)
    const minutes = Math.floor((totalSeconds % 3600) / 60)
    const seconds = totalSeconds % 60
    return `${String(hours).padStart(2, '0')}:${String(minutes).padStart(2, '0')}:${String(seconds).padStart(2, '0')}`
  }
}
