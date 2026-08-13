import { Controller } from "@hotwired/stimulus"

// "Continue with Atlassian" is in the design, but no Atlassian OAuth exists in
// the app yet. Rather than a button that silently does nothing when clicked,
// this reveals a short note pointing the user at the email form above.
export default class extends Controller {
  static targets = ["note"]

  explain() {
    this.noteTarget.classList.remove("hidden")
  }
}
