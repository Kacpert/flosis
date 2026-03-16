import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["projectSelect", "boardSelect", "sprintSelect", "boardContent", "viewToggle", "refreshButton"]
  static values = { currentView: { type: String, default: "kanban" } }

  projectChanged() {
    const projectId = this.projectSelectTarget.value
    if (!projectId) return

    window.location.href = `/jira_tasks?project_id=${projectId}&view=${this.currentViewValue}`
  }

  boardChanged() {
    this.reloadBoardContent()
  }

  sprintChanged() {
    this.reloadBoardContent()
  }

  toggleView(event) {
    const view = event.currentTarget.dataset.view
    if (view === this.currentViewValue) return

    this.currentViewValue = view

    this.viewToggleTargets.forEach(btn => {
      const isActive = btn.dataset.view === view
      btn.style.background = isActive ? "var(--color-primary)" : "var(--color-surface)"
      btn.style.color = isActive ? "var(--color-on-primary)" : "var(--color-on-surface-variant)"
    })

    this.reloadBoardContent()
  }

  refresh() {
    const projectId = this.hasProjectSelectTarget ? this.projectSelectTarget.value : null
    if (!projectId) return

    const btn = this.refreshButtonTarget
    btn.disabled = true
    btn.innerHTML = `<svg class="animate-spin h-4 w-4" viewBox="0 0 24 24"><circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4" fill="none"/><path class="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4z"/></svg> Syncing...`

    const params = new URLSearchParams({ project_id: projectId })
    if (this.hasBoardSelectTarget) params.set("board_id", this.boardSelectTarget.value)
    if (this.hasSprintSelectTarget && this.sprintSelectTarget.value) params.set("sprint_id", this.sprintSelectTarget.value)
    params.set("view", this.currentViewValue)

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

  reloadBoardContent() {
    if (!this.hasBoardContentTarget) return

    const projectId = this.hasProjectSelectTarget ? this.projectSelectTarget.value : null
    const boardId = this.hasBoardSelectTarget ? this.boardSelectTarget.value : null
    if (!projectId || !boardId) return

    const params = new URLSearchParams({
      project_id: projectId,
      board_id: boardId,
      view: this.currentViewValue
    })

    if (this.hasSprintSelectTarget && this.sprintSelectTarget.value) {
      params.set("sprint_id", this.sprintSelectTarget.value)
    }

    this.boardContentTarget.src = `/jira_tasks/board_data?${params}`
  }
}
