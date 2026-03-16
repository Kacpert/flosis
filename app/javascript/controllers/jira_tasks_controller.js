import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["projectSelect", "boardSelect", "sprintSelect", "boardContent", "viewToggle", "refreshButton"]
  static values = { currentView: { type: String, default: "kanban" } }

  projectChanged() {
    // Reset board and sprint when project changes
    if (this.hasBoardSelectTarget) this.boardSelectTarget.value = ""
    if (this.hasSprintSelectTarget) this.sprintSelectTarget.value = ""
    this.navigateWithParams()
  }

  boardChanged() {
    // Reset sprint when board changes since sprints are board-specific
    if (this.hasSprintSelectTarget) {
      this.sprintSelectTarget.value = ""
    }
    this.navigateWithParams()
  }

  sprintChanged() {
    this.navigateWithParams()
  }

  toggleView(event) {
    const view = event.currentTarget.dataset.view
    if (view === this.currentViewValue) return

    this.currentViewValue = view
    this.navigateWithParams()
  }

  refresh() {
    const projectId = this.hasProjectSelectTarget ? this.projectSelectTarget.value : null
    if (!projectId) return

    const btn = this.refreshButtonTarget
    btn.disabled = true
    btn.innerHTML = `<svg class="animate-spin h-4 w-4" viewBox="0 0 24 24"><circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4" fill="none"/><path class="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4z"/></svg> Syncing...`

    const params = this.buildParams()
    const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content

    fetch(`/jira_tasks/refresh?${params}`, {
      method: "POST",
      headers: {
        "X-CSRF-Token": csrfToken,
        "Accept": "text/html"
      }
    }).then(response => {
      if (response.redirected) {
        window.location.href = response.url
      } else {
        window.location.reload()
      }
    }).catch(() => {
      window.location.reload()
    })
  }

  // private

  navigateWithParams() {
    const params = this.buildParams()
    window.location.href = `/jira_tasks?${params}`
  }

  buildParams() {
    const params = new URLSearchParams()

    if (this.hasProjectSelectTarget && this.projectSelectTarget.value) {
      params.set("project_id", this.projectSelectTarget.value)
    }
    if (this.hasBoardSelectTarget && this.boardSelectTarget.value) {
      params.set("board_id", this.boardSelectTarget.value)
    }
    if (this.hasSprintSelectTarget && this.sprintSelectTarget.value) {
      params.set("sprint_id", this.sprintSelectTarget.value)
    }
    params.set("view", this.currentViewValue)

    return params
  }
}
