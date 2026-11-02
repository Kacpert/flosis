import { Controller } from "@hotwired/stimulus"

// The alert-rule schedule builder: mode (Daily / Days / Every X h), the weekdays
// it may run on, a time-of-day or an hour interval, and an optional "only
// between" window for interval mode. Mirrors AlertRule#schedule_label so the
// "Runs …" preview always reads exactly like the rule card will after saving.
const DAY_NAMES = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
const WEEKDAYS = ["Mon", "Tue", "Wed", "Thu", "Fri"]
const WEEKENDS = ["Sat", "Sun"]

export default class extends Controller {
  static targets = [
    "modeButton", "modeField", "dayButton", "daysField", "daysRow",
    "timeRow", "intervalRow", "intervalField", "timeField",
    "windowRow", "windowToggle", "windowField", "windowInputs",
    "preview",
  ]
  static values = { mode: String, days: String, window: Boolean }

  connect() {
    this.render()
  }

  selectMode(event) {
    this.modeValue = event.currentTarget.dataset.mode
    this.render()
  }

  toggleDay(event) {
    const day = event.currentTarget.dataset.day
    const set = new Set(this.days)
    set.has(day) ? set.delete(day) : set.add(day)
    this.daysValue = DAY_NAMES.filter((d) => set.has(d)).join(",")
    this.render()
  }

  // One button that flips between "all seven" and "weekdays only".
  toggleAllDays() {
    this.daysValue = this.days.length === 7 ? WEEKDAYS.join(",") : DAY_NAMES.join(",")
    this.render()
  }

  toggleWindow() {
    this.windowValue = !this.windowValue
    this.render()
  }

  refresh() {
    this.render()
  }

  get days() {
    return (this.daysValue || "").split(",").filter((d) => DAY_NAMES.includes(d))
  }

  get mode() {
    return this.modeValue || "daily"
  }

  render() {
    const mode = this.mode
    const days = this.days
    const interval = mode === "interval"

    this.modeButtonTargets.forEach((btn) => {
      btn.classList.toggle("clar-seg-item-active", btn.dataset.mode === mode)
    })
    this.dayButtonTargets.forEach((btn) => {
      btn.classList.toggle("clar-daychip-active", days.includes(btn.dataset.day))
    })

    // Day chips are only meaningful when the schedule is day-scoped.
    this.daysRowTarget.classList.toggle("hidden", mode === "daily")
    this.timeRowTarget.classList.toggle("hidden", interval)
    this.intervalRowTarget.classList.toggle("hidden", !interval)
    this.windowRowTarget.classList.toggle("hidden", !interval)
    this.windowInputsTarget.classList.toggle("hidden", !this.windowValue)
    this.windowToggleTarget.setAttribute("aria-checked", this.windowValue ? "true" : "false")

    this.modeFieldTarget.value = mode
    // "Daily" means every day — send the full set so the server agrees.
    this.daysFieldTarget.value = mode === "daily" ? DAY_NAMES.join(",") : days.join(",")
    this.windowFieldTarget.value = this.windowValue ? "1" : "0"

    this.previewTarget.textContent = this.scheduleLabel()
  }

  // Keep in lockstep with AlertRule#schedule_label.
  scheduleLabel() {
    const label = this.dayLabel()
    const time = this.timeFieldTarget.value || "09:00"

    if (this.mode === "interval") {
      const hours = Math.min(24, Math.max(1, parseInt(this.intervalFieldTarget.value, 10) || 1))
      const parts = [label, `Every ${hours}h`].filter(Boolean)
      if (this.windowValue) {
        const [from, to] = this.windowInputsTarget.querySelectorAll("input[type=time]")
        parts.push(`${from.value}–${to.value}`)
      }
      return parts.join(" · ")
    }

    return `${label || "Daily"} · ${time}`
  }

  dayLabel() {
    const days = this.mode === "daily" ? DAY_NAMES : this.days
    if (days.length === 0 || days.length === DAY_NAMES.length) return ""
    if (days.join() === WEEKDAYS.join()) return "Weekdays"
    if (days.join() === WEEKENDS.join()) return "Weekends"
    return days.join(", ")
  }
}
