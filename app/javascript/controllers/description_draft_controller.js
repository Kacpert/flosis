import { Controller } from "@hotwired/stimulus"

// Keeps what you typed in the timer bar's description box from evaporating.
//
// Timer mode and manual mode are two separate forms with two separate inputs,
// so switching modes used to look like the text vanished. A project change or
// an accidental refresh reloads the page and took it with it. One draft, shared
// by both inputs and persisted, survives all three.
//
// Only used while NO timer is running. Once one is, the description lives in
// the database and a stale draft must never overwrite it.
const KEY = "gold_timer_description_draft"

export default class extends Controller {
  static targets = ["input"]

  connect() {
    const draft = this.read()
    if (!draft) return

    // Never clobber a value the server put there.
    this.inputTargets.forEach((input) => {
      if (!input.value) input.value = draft
    })
  }

  // Mirrors into the other mode's input as you type, so toggling modes shows
  // the same text rather than an empty box.
  save(event) {
    const value = event.target.value
    this.write(value)

    this.inputTargets.forEach((input) => {
      if (input !== event.target) input.value = value
    })
  }

  // Only once the submission actually succeeded. Clearing on plain submit would
  // throw the text away exactly when a validation error means you still need it.
  clearIfSuccess(event) {
    if (event.detail?.success) this.clear()
  }

  // The text has become a real time entry — the draft has done its job.
  clear() {
    try {
      localStorage.removeItem(KEY)
    } catch (e) {
      // private mode / storage disabled
    }
    this.inputTargets.forEach((input) => { input.value = "" })
  }

  read() {
    try {
      return localStorage.getItem(KEY)
    } catch (e) {
      return null
    }
  }

  write(value) {
    try {
      if (value) {
        localStorage.setItem(KEY, value)
      } else {
        localStorage.removeItem(KEY)
      }
    } catch (e) {
      // private mode / storage disabled
    }
  }
}
