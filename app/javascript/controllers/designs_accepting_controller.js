import { Controller } from "@hotwired/stimulus"

// Accept designs, as it goes (Kacper, 2026-11-23: "żeby user wiedział na co
// czeka"). In the dialog, Accept puts the steps it waits for in place of the
// question, the first under way, while the merge is made. While it runs, the
// acceptance has a window of its own over the Designs screen, polled with the
// chat: Hide (or a click beside it) puts it away for that acceptance in this
// tab, and the chat still shows the steps.
export default class extends Controller {
  static targets = [ "confirm", "progress" ]
  static values = { key: String }

  connect() {
    if (this.keyValue && this.remembered()) this.element.classList.add("hidden")
  }

  start() {
    this.confirmTargets.forEach((element) => element.classList.add("hidden"))
    this.progressTargets.forEach((element) => element.classList.remove("hidden"))
  }

  hide() {
    this.element.classList.add("hidden")
    try { sessionStorage.setItem(this.keyValue, "1") } catch {}
  }

  keep(event) {
    event.stopPropagation()
  }

  remembered() {
    try { return sessionStorage.getItem(this.keyValue) === "1" } catch { return false }
  }
}
