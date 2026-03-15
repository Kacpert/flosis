import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["input", "dropdown", "list", "taskId"]
  static values = { tasks: Array, jiraConnected: Boolean }

  connect() {
    this.clickOutside = this.clickOutside.bind(this)
    document.addEventListener("mousedown", this.clickOutside)

    // Store direct references before we move elements to body
    this._dropdown = this.hasDropdownTarget ? this.dropdownTarget : null
    this._list = this.hasListTarget ? this.listTarget : null

    // If already connected to Jira (running timer), load tasks on page load
    if (this.jiraConnectedValue) {
      this.loadTasksForCurrentProject()
    }
  }

  disconnect() {
    document.removeEventListener("mousedown", this.clickOutside)
    if (this._dropdown && this._dropdown.parentElement === document.body) {
      this._dropdown.remove()
    }
  }

  async projectChanged(event) {
    const projectId = event.target.value
    this.jiraConnectedValue = false
    this.tasksValue = []

    if (!projectId) {
      this.hideTaskSelect(false)
      return
    }

    try {
      const response = await fetch(`/projects/${projectId}/jira_tasks`, {
        headers: { "Accept": "application/json" }
      })

      if (!response.ok) {
        this.hideTaskSelect(false)
        return
      }

      const tasks = await response.json()

      if (tasks.length > 0) {
        this.jiraConnectedValue = true
        this.tasksValue = tasks
        this.hideTaskSelect(true)
      } else {
        this.hideTaskSelect(false)
      }
    } catch (e) {
      this.hideTaskSelect(false)
    }
  }

  async loadTasksForCurrentProject() {
    const form = this.element.closest("form") || this.element
    const projectSelect = form.querySelector("select[name*='project_id']")
    if (!projectSelect || !projectSelect.value) return

    try {
      const response = await fetch(`/projects/${projectSelect.value}/jira_tasks`, {
        headers: { "Accept": "application/json" }
      })
      if (response.ok) {
        const tasks = await response.json()
        if (tasks.length > 0) {
          this.tasksValue = tasks
          this.jiraConnectedValue = true
          this.hideTaskSelect(true)
        }
      }
    } catch (e) {
      // silently fail
    }
  }

  focus() {
    if (this._justSelected) return
    if (!this.jiraConnectedValue || this.tasksValue.length === 0) return
    this.renderList()
    this.show()
  }

  filter() {
    if (!this.jiraConnectedValue) return
    this.renderList(this.inputTarget.value)
    this.show()
  }

  renderList(query = "") {
    if (!this._list) return

    const tasks = this.fuzzyFilter(this.tasksValue, query)
    this._list.innerHTML = ""

    if (tasks.length === 0) {
      const empty = document.createElement("div")
      empty.className = "px-3 py-2 text-sm"
      empty.style.color = "var(--color-on-surface-variant)"
      empty.textContent = "No matching tasks"
      this._list.appendChild(empty)
      return
    }

    tasks.forEach(task => {
      const item = document.createElement("div")
      item.style.cssText = "padding: 8px 12px; cursor: pointer; display: flex; align-items: center; gap: 8px; transition: background 0.15s;"
      item.addEventListener("mouseenter", () => { item.style.background = "var(--color-surface-container-high)" })
      item.addEventListener("mouseleave", () => { item.style.background = "transparent" })

      const key = document.createElement("a")
      key.className = "text-xs font-semibold flex-shrink-0 hover:underline"
      key.style.color = "var(--color-primary)"
      key.textContent = task.external_reference || ""
      if (task.external_url) {
        key.href = task.external_url
        key.target = "_blank"
        key.rel = "noopener"
        key.addEventListener("mousedown", (e) => e.stopPropagation())
      }

      const summary = document.createElement("span")
      summary.className = "text-sm flex-1 truncate"
      summary.style.color = "var(--color-on-surface)"
      const nameWithoutKey = task.name.replace(`${task.external_reference} `, "")
      summary.textContent = nameWithoutKey

      item.appendChild(key)
      item.appendChild(summary)

      if (task.status_name) {
        const badge = document.createElement("span")
        badge.className = "text-xs px-1.5 py-0.5 rounded-full flex-shrink-0"
        badge.style.cssText = "background: var(--color-secondary-container); color: var(--color-on-secondary-container); font-size: 0.65rem;"
        badge.textContent = task.status_name
        item.appendChild(badge)
      }

      item.addEventListener("mousedown", (e) => {
        e.preventDefault() // Prevent blur on input
        this.selectTask(task)
      })
      this._list.appendChild(item)
    })
  }

  selectTask(task) {
    if (this.hasInputTarget) {
      this.inputTarget.value = task.name
    }
    if (this.hasTaskIdTarget) {
      this.taskIdTarget.value = task.id
    }
    this.hide()

    // Trigger auto-save if available
    this._justSelected = true
    this.inputTarget.dispatchEvent(new Event("blur", { bubbles: true }))
    setTimeout(() => { this._justSelected = false }, 300)
  }

  fuzzyFilter(tasks, query) {
    if (!query || query.trim() === "") return tasks

    const q = query.toLowerCase()
    return tasks.filter(t => {
      const name = t.name.toLowerCase()
      const ref = (t.external_reference || "").toLowerCase()
      let qi = 0
      for (let i = 0; i < name.length && qi < q.length; i++) {
        if (name[i] === q[qi]) qi++
      }
      return qi === q.length || ref.includes(q)
    })
  }

  show() {
    if (!this._dropdown) return

    const rect = this.inputTarget.getBoundingClientRect()

    // Move dropdown to body so it's not clipped by any parent stacking context
    if (this._dropdown.parentElement !== document.body) {
      document.body.appendChild(this._dropdown)
    }

    this._dropdown.style.position = "fixed"
    this._dropdown.style.top = `${rect.bottom + 4}px`
    this._dropdown.style.left = `${rect.left}px`
    this._dropdown.style.width = `${rect.width}px`
    this._dropdown.style.zIndex = "99999"
    this._dropdown.classList.remove("hidden")
  }

  hide() {
    if (this._dropdown) {
      this._dropdown.classList.add("hidden")
    }
  }

  clickOutside(event) {
    if (!this._dropdown) return
    if (this._dropdown.classList.contains("hidden")) return

    if (!this.element.contains(event.target) && !this._dropdown.contains(event.target)) {
      this.hide()
    }
  }

  hideTaskSelect(hide) {
    const form = this.element.closest("form")
    if (!form) return
    const taskSelect = form.querySelector("[data-jira-task-select]")
    if (taskSelect) {
      taskSelect.style.display = hide ? "none" : ""
    }
  }

  keydown(event) {
    if (event.key === "Escape") {
      this.hide()
      event.preventDefault()
    }
  }
}
