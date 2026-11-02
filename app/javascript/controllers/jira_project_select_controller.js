import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["select", "status"]
  static values = { currentKey: String }

  connect() {
    this.loadProjects()
  }

  async loadProjects() {
    this.statusTarget.textContent = "Loading Jira projects..."

    try {
      const response = await fetch("/jira/projects", {
        headers: { "Accept": "application/json" }
      })

      if (!response.ok) {
        this.statusTarget.textContent = "Could not connect to Jira"
        return
      }

      const projects = await response.json()

      if (projects.length === 0) {
        this.statusTarget.textContent = "No Jira projects found"
        return
      }

      this.statusTarget.textContent = ""
      this.selectTarget.innerHTML = '<option value="">No Jira project</option>'

      projects.forEach(project => {
        const option = document.createElement("option")
        option.value = project.key
        option.textContent = `${project.key} — ${project.name}`
        if (project.key === this.currentKeyValue) {
          option.selected = true
        }
        this.selectTarget.appendChild(option)
      })

      this.selectTarget.disabled = false
    } catch (e) {
      this.statusTarget.textContent = "Could not connect to Jira"
    }
  }

  select(event) {
    const key = event.target.value
    const typeField = this.element.querySelector("[data-jira-type-field]")
    const refField = this.element.querySelector("[data-jira-ref-field]")

    if (typeField) typeField.value = key ? "jira" : ""
    if (refField) refField.value = key
  }
}
