import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["startTime", "duration", "endTime"]

  connect() {
    this.updateEndTime()
  }

  // Called when start time changes
  startTimeChanged() {
    this.updateEndTime()
  }

  // Called when duration field loses focus — validate and format
  durationChanged() {
    const raw = this.durationTarget.value.trim()
    if (!raw) return

    const seconds = this.parseDuration(raw)
    if (seconds === null || seconds <= 0 || seconds > 86400) {
      // Invalid or > 24 hours — reset to empty
      this.durationTarget.value = ""
      this.updateEndTime()
      return
    }

    // Format nicely
    this.durationTarget.value = this.formatDuration(seconds)
    this.updateEndTime()
  }

  // Called on keydown in duration field — only allow valid chars
  durationKeydown(event) {
    // Allow: backspace, delete, tab, escape, enter, arrows, colon, period
    const allowed = ["Backspace", "Delete", "Tab", "Escape", "Enter",
                     "ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown",
                     ":", ".", "Home", "End"]
    if (allowed.includes(event.key)) return
    // Allow digits
    if (/^\d$/.test(event.key)) return
    // Block everything else
    event.preventDefault()
  }

  updateEndTime() {
    if (!this.hasEndTimeTarget) return

    const startVal = this.hasStartTimeTarget ? this.startTimeTarget.value : null
    const durationVal = this.hasDurationTarget ? this.durationTarget.value.trim() : null

    if (!startVal || !durationVal) {
      this.endTimeTarget.textContent = ""
      return
    }

    const seconds = this.parseDuration(durationVal)
    if (!seconds || seconds <= 0) {
      this.endTimeTarget.textContent = ""
      return
    }

    const start = new Date(startVal)
    if (isNaN(start.getTime())) {
      this.endTimeTarget.textContent = ""
      return
    }

    const end = new Date(start.getTime() + seconds * 1000)
    const endStr = end.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", hour12: false })
    this.endTimeTarget.textContent = `→ ${endStr}`
  }

  // Parse various duration formats into seconds
  // Supported: "1:30" (1h30m), "1:30:00" (1h30m0s), "1.5" (1.5h), "90" (90min if ≤ 600, else invalid)
  parseDuration(str) {
    if (!str) return null

    // H:MM or H:MM:SS format
    const colonMatch = str.match(/^(\d{1,3}):(\d{2})(?::(\d{2}))?$/)
    if (colonMatch) {
      const hours = parseInt(colonMatch[1])
      const minutes = parseInt(colonMatch[2])
      const seconds = colonMatch[3] ? parseInt(colonMatch[3]) : 0
      if (minutes >= 60 || seconds >= 60) return null
      return hours * 3600 + minutes * 60 + seconds
    }

    // Decimal hours: "1.5" = 1h30m
    const decimalMatch = str.match(/^(\d{1,2})\.(\d{1,2})$/)
    if (decimalMatch) {
      return Math.round(parseFloat(str) * 3600)
    }

    // Plain number: treat as minutes if ≤ 480 (8 hours), reject otherwise
    const plainMatch = str.match(/^(\d{1,3})$/)
    if (plainMatch) {
      const num = parseInt(plainMatch[1])
      if (num <= 480) return num * 60
      return null
    }

    return null
  }

  formatDuration(totalSeconds) {
    const hours = Math.floor(totalSeconds / 3600)
    const minutes = Math.floor((totalSeconds % 3600) / 60)
    return `${hours}:${String(minutes).padStart(2, "0")}`
  }
}
