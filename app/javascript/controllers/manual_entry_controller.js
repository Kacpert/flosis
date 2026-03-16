import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = [
    "startTime", "endTime", "duration",
    "startDate", "endDate",
    "startedAt", "stoppedAt",
    "dateButton", "overnightBadge", "endDateWrap"
  ]

  connect() {
    this.endDateOverride = null
    this.syncHiddenFields()

    // Prevent form submission without a valid stopped_at
    this.element.closest("form")?.addEventListener("submit", (e) => {
      this.syncHiddenFields()
      if (this.hasStoppedAtTarget && !this.stoppedAtTarget.value) {
        e.preventDefault()
        const target = this.hasEndTimeTarget ? this.endTimeTarget : this.durationTarget
        if (target) {
          target.style.borderColor = "var(--color-error)"
          setTimeout(() => { target.style.borderColor = "" }, 2000)
        }
      }
    })
  }

  startTimeChanged() {
    this.formatTimeInput(this.startTimeTarget)
    if (this.hasEndTimeValue()) {
      this.recalcDuration()
    } else if (this.hasDurationValue()) {
      this.recalcEndTime()
    }
    this.updateOvernight()
    this.syncHiddenFields()
  }

  endTimeChanged() {
    this.formatTimeInput(this.endTimeTarget)
    if (this.hasStartTimeValue()) {
      this.recalcDuration()
    } else if (this.hasDurationValue()) {
      this.recalcStartTime()
    }
    this.updateOvernight()
    this.syncHiddenFields()
  }

  durationChanged() {
    const raw = this.durationTarget.value.trim()
    if (!raw) {
      this.syncHiddenFields()
      return
    }
    const seconds = this.parseDuration(raw)
    if (seconds === null || seconds <= 0 || seconds > 86400) {
      this.durationTarget.value = ""
      this.syncHiddenFields()
      return
    }
    this.durationTarget.value = this.formatDuration(seconds)

    if (this.hasStartTimeValue()) {
      this.recalcEndTime()
    } else if (this.hasEndTimeValue()) {
      this.recalcStartTime()
    }
    this.updateOvernight()
    this.syncHiddenFields()
  }

  dateChanged() {
    this.endDateOverride = null
    this.updateOvernight()
    this.syncHiddenFields()
    this.updateDateButtonText()
  }

  toggleEndDate(event) {
    event.preventDefault()
    if (this.hasEndDateWrapTarget) {
      this.endDateWrapTarget.classList.toggle("hidden")
    }
  }

  endDateChanged() {
    const endDateVal = this.endDateTarget.value
    const startDateVal = this.startDateTarget.value
    if (endDateVal && endDateVal !== startDateVal) {
      this.endDateOverride = endDateVal
    } else {
      this.endDateOverride = null
    }
    this.updateOvernight()
    this.syncHiddenFields()
  }

  timeKeydown(event) {
    const allowed = ["Backspace", "Delete", "Tab", "Escape", "Enter",
                     "ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown",
                     ":", "Home", "End"]
    if (allowed.includes(event.key)) return
    if (/^\d$/.test(event.key)) return
    event.preventDefault()
  }

  durationKeydown(event) {
    const allowed = ["Backspace", "Delete", "Tab", "Escape", "Enter",
                     "ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown",
                     ":", ".", "Home", "End"]
    if (allowed.includes(event.key)) return
    if (/^\d$/.test(event.key)) return
    event.preventDefault()
  }

  formatTimeInput(input) {
    const raw = input.value.trim().replace(/[^0-9:]/g, "")
    if (!raw) return

    let hours, minutes

    const colonMatch = raw.match(/^(\d{1,2}):(\d{2})$/)
    if (colonMatch) {
      hours = parseInt(colonMatch[1])
      minutes = parseInt(colonMatch[2])
    }
    else if (/^\d{4}$/.test(raw)) {
      hours = parseInt(raw.substring(0, 2))
      minutes = parseInt(raw.substring(2, 4))
    }
    else if (/^\d{3}$/.test(raw)) {
      hours = parseInt(raw.substring(0, 1))
      minutes = parseInt(raw.substring(1, 3))
    }
    else if (/^\d{1,2}$/.test(raw)) {
      hours = parseInt(raw)
      minutes = 0
    }
    else if (/^\d{1,2}:$/.test(raw)) {
      hours = parseInt(raw)
      minutes = 0
    }
    else {
      input.value = ""
      return
    }

    if (hours > 23 || minutes > 59) {
      input.value = ""
      return
    }

    input.value = `${String(hours).padStart(2, "0")}:${String(minutes).padStart(2, "0")}`
  }

  recalcDuration() {
    const startMinutes = this.parseTime(this.startTimeTarget.value)
    const endMinutes = this.parseTime(this.endTimeTarget.value)
    if (startMinutes === null || endMinutes === null) return

    let diff = endMinutes - startMinutes
    if (diff < 0) diff += 24 * 60

    if (this.endDateOverride && this.hasStartDateTarget) {
      const startDate = new Date(this.startDateTarget.value)
      const endDate = new Date(this.endDateOverride)
      const daysDiff = Math.round((endDate - startDate) / (24 * 60 * 60 * 1000))
      if (daysDiff > 0) {
        diff = (daysDiff * 24 * 60) + (endMinutes - startMinutes)
      }
    }

    this.durationTarget.value = this.formatDuration(diff * 60)
  }

  recalcEndTime() {
    const startMinutes = this.parseTime(this.startTimeTarget.value)
    const durationSeconds = this.parseDuration(this.durationTarget.value)
    if (startMinutes === null || durationSeconds === null) return

    const endMinutes = startMinutes + Math.floor(durationSeconds / 60)
    const h = Math.floor((endMinutes % (24 * 60)) / 60)
    const m = endMinutes % 60
    this.endTimeTarget.value = `${String(h).padStart(2, "0")}:${String(m).padStart(2, "0")}`
  }

  recalcStartTime() {
    const endMinutes = this.parseTime(this.endTimeTarget.value)
    const durationSeconds = this.parseDuration(this.durationTarget.value)
    if (endMinutes === null || durationSeconds === null) return

    let startMinutes = endMinutes - Math.floor(durationSeconds / 60)
    if (startMinutes < 0) startMinutes += 24 * 60
    const h = Math.floor(startMinutes / 60)
    const m = startMinutes % 60
    this.startTimeTarget.value = `${String(h).padStart(2, "0")}:${String(m).padStart(2, "0")}`
  }

  updateOvernight() {
    if (!this.hasOvernightBadgeTarget) return

    const startMinutes = this.parseTime(this.startTimeTarget.value)
    const endMinutes = this.parseTime(this.endTimeTarget.value)

    if (startMinutes === null || endMinutes === null) {
      this.overnightBadgeTarget.classList.add("hidden")
      return
    }

    const isOvernight = endMinutes < startMinutes || this.endDateOverride
    if (isOvernight) {
      let daysDiff = 1
      if (this.endDateOverride && this.hasStartDateTarget) {
        const startDate = new Date(this.startDateTarget.value)
        const endDate = new Date(this.endDateOverride)
        daysDiff = Math.round((endDate - startDate) / (24 * 60 * 60 * 1000))
      }
      this.overnightBadgeTarget.textContent = `+${daysDiff}d`
      this.overnightBadgeTarget.classList.remove("hidden")
    } else {
      this.overnightBadgeTarget.classList.add("hidden")
    }
  }

  syncHiddenFields() {
    if (!this.hasStartedAtTarget || !this.hasStartDateTarget) return

    const startDate = this.startDateTarget.value
    const startTime = this.startTimeTarget.value
    const endTime = this.hasEndTimeTarget ? this.endTimeTarget.value : ""

    if (startDate && startTime && startTime.includes(":")) {
      this.startedAtTarget.value = `${startDate}T${startTime}`
    }

    if (this.hasStoppedAtTarget && endTime && endTime.includes(":")) {
      let endDate = startDate
      const startMinutes = this.parseTime(startTime)
      const endMinutes = this.parseTime(endTime)

      if (this.endDateOverride) {
        endDate = this.endDateOverride
      } else if (startMinutes !== null && endMinutes !== null && endMinutes < startMinutes) {
        const d = new Date(startDate)
        d.setDate(d.getDate() + 1)
        endDate = d.toISOString().split("T")[0]
      }

      this.stoppedAtTarget.value = `${endDate}T${endTime}`
    } else if (this.hasStoppedAtTarget) {
      this.stoppedAtTarget.value = ""
    }
  }

  updateDateButtonText() {
    if (!this.hasDateButtonTarget || !this.hasStartDateTarget) return
    const dateVal = this.startDateTarget.value
    if (!dateVal) return
    const date = new Date(dateVal + "T00:00:00")
    const day = date.getDate()
    const month = date.toLocaleDateString("en-US", { month: "short" })
    this.dateButtonTarget.textContent = `${day} ${month}`
  }

  parseTime(str) {
    if (!str) return null
    const match = str.match(/^(\d{2}):(\d{2})$/)
    if (!match) return null
    const h = parseInt(match[1])
    const m = parseInt(match[2])
    if (h > 23 || m > 59) return null
    return h * 60 + m
  }

  parseDuration(str) {
    if (!str) return null
    const colonMatch = str.match(/^(\d{1,3}):(\d{2})(?::(\d{2}))?$/)
    if (colonMatch) {
      const hours = parseInt(colonMatch[1])
      const minutes = parseInt(colonMatch[2])
      const seconds = colonMatch[3] ? parseInt(colonMatch[3]) : 0
      if (minutes >= 60 || seconds >= 60) return null
      return hours * 3600 + minutes * 60 + seconds
    }
    const decimalMatch = str.match(/^(\d{1,2})\.(\d{1,2})$/)
    if (decimalMatch) {
      return Math.round(parseFloat(str) * 3600)
    }
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

  hasStartTimeValue() {
    return this.hasStartTimeTarget && this.startTimeTarget.value.trim() !== ""
  }

  hasEndTimeValue() {
    return this.hasEndTimeTarget && this.endTimeTarget.value.trim() !== ""
  }

  hasDurationValue() {
    return this.hasDurationTarget && this.durationTarget.value.trim() !== ""
  }
}
