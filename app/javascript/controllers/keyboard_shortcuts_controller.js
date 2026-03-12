import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["modal"]

  connect() {
    this.pendingKey = null
    this.handleKeydown = this.handleKeydown.bind(this)
    document.addEventListener("keydown", this.handleKeydown)
  }

  disconnect() {
    document.removeEventListener("keydown", this.handleKeydown)
  }

  handleKeydown(event) {
    // Ignore when typing in form fields
    const tag = event.target.tagName
    if (tag === "INPUT" || tag === "TEXTAREA" || tag === "SELECT" || event.target.isContentEditable) {
      return
    }

    const key = event.key.toLowerCase()

    // Two-key combos with "g"
    if (this.pendingKey === "g") {
      this.pendingKey = null
      event.preventDefault()
      switch (key) {
        case "d": window.location.href = "/"; break
        case "t": window.location.href = "/time_entries"; break
        case "p": window.location.href = "/projects"; break
        case "r": window.location.href = "/reports/summary"; break
        case "s": window.location.href = "/timesheet"; break
        case "c": window.location.href = "/clients"; break
      }
      return
    }

    switch (key) {
      case "g":
        this.pendingKey = "g"
        setTimeout(() => { this.pendingKey = null }, 1000)
        break
      case "s":
        event.preventDefault()
        // Focus timer description or click stop if running
        const stopBtn = document.querySelector("[action='/timer/stop'] button, [action='/timer/stop'] input[type='submit']")
        if (stopBtn) {
          stopBtn.click()
        } else {
          const timerInput = document.querySelector("input[name='description']")
          if (timerInput) timerInput.focus()
        }
        break
      case "n":
        event.preventDefault()
        window.location.href = "/time_entries/new"
        break
      case "?":
        event.preventDefault()
        this.toggleHelp()
        break
    }
  }

  toggleHelp() {
    if (this.hasModalTarget) {
      this.modalTarget.classList.toggle("modal-open")
    }
  }

  closeHelp() {
    if (this.hasModalTarget) {
      this.modalTarget.classList.remove("modal-open")
    }
  }
}
