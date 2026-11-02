import { Controller } from "@hotwired/stimulus"

// Click the running counter to correct when you actually started — you notice
// ten minutes in that you forgot to hit play. The pill swaps to an HH:MM field
// showing the real start time; Enter or blur saves, Escape cancels.
//
// Only the time-of-day is editable. The date comes from the existing start, and
// a time that would land in the future is read as "yesterday at that hour"
// (past midnight, typing 14:05 can only mean yesterday afternoon). The server
// applies the same rule, so a stale tab cannot push the start into the future.
export default class extends Controller {
  static targets = ["display", "input", "form", "startedAt"]
  static values = { startedAt: String }

  edit() {
    if (this.editing) return
    this.editing = true

    const start = new Date(this.startedAtValue)
    this.inputTarget.value = this.formatClock(start)

    this.displayTarget.classList.add("hidden")
    this.inputTarget.classList.remove("hidden")
    this.inputTarget.focus()
    this.inputTarget.select()
  }

  keydown(event) {
    if (event.key === "Enter") {
      event.preventDefault()
      this.inputTarget.blur() // blur commits
    } else if (event.key === "Escape") {
      event.preventDefault()
      this.cancel()
    }
  }

  commit() {
    if (!this.editing) return

    const parsed = this.parseClock(this.inputTarget.value)
    if (!parsed) return this.cancel()

    const start = new Date(this.startedAtValue)
    start.setHours(parsed.hours, parsed.minutes, 0, 0)
    // Past midnight, a time later than "now" can only mean earlier the same
    // evening — otherwise the counter would run backwards.
    if (start.getTime() > Date.now()) start.setDate(start.getDate() - 1)

    this.startedAtTarget.value = this.formatLocalIso(start)
    this.formTarget.requestSubmit()
  }

  cancel() {
    this.editing = false
    this.inputTarget.classList.add("hidden")
    this.displayTarget.classList.remove("hidden")
  }

  // Accepts 14:05, 1405, 14.05 and 14 — the same shapes the manual entry row
  // takes, so the two time fields behave alike.
  parseClock(raw) {
    const value = (raw || "").trim()
    if (!value) return null

    const match = value.match(/^(\d{1,2})[:.\s]?(\d{2})?$/)
    if (!match) return null

    const hours = parseInt(match[1], 10)
    const minutes = match[2] ? parseInt(match[2], 10) : 0
    if (hours > 23 || minutes > 59) return null

    return { hours, minutes }
  }

  formatClock(date) {
    return `${String(date.getHours()).padStart(2, "0")}:${String(date.getMinutes()).padStart(2, "0")}`
  }

  // A local "YYYY-MM-DDTHH:MM" — toISOString() would shift into UTC and move
  // the start by the timezone offset.
  formatLocalIso(date) {
    const pad = (n) => String(n).padStart(2, "0")
    return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}T${pad(date.getHours())}:${pad(date.getMinutes())}`
  }
}
