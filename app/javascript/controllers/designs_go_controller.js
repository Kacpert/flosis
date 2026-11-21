import { Controller } from "@hotwired/stimulus"

// Accept designs (2026-11-21): once a task's description is written from its
// accepted designs, the thread's chat renders this for whoever accepted them,
// and it takes them back to the task, where a modal says what changed.
export default class extends Controller {
  static values = { url: String }

  connect() {
    if (this.urlValue) window.Turbo.visit(this.urlValue)
  }
}
