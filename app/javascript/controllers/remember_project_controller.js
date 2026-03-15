import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  save(event) {
    const projectId = event.target.value
    if (projectId) {
      localStorage.setItem("gold_last_project_id", projectId)
    } else {
      localStorage.removeItem("gold_last_project_id")
    }
  }
}
