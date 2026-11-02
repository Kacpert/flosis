import { Controller } from "@hotwired/stimulus"

// One in-flight request per project, shared by every instance of this
// controller on the page (the bar renders a start form AND a manual-entry
// form, and both want the same list). The short TTL keeps a newly created
// Jira ticket from being invisible for a whole browsing session, since Turbo
// keeps this module alive across navigations.
const TASK_CACHE_TTL = 60_000
const taskCache = new Map() // projectId -> { at, promise }

function fetchTasks(projectId) {
  const hit = taskCache.get(projectId)
  if (hit && Date.now() - hit.at < TASK_CACHE_TTL) return hit.promise

  const promise = fetch(`/projects/${projectId}/jira_tasks`, {
    headers: { "Accept": "application/json" }
  })
    .then(response => (response.ok ? response.json() : []))
    .catch(() => [])

  taskCache.set(projectId, { at: Date.now(), promise })
  return promise
}

export default class extends Controller {
  static targets = ["input", "dropdown", "list", "taskId"]
  static values = { tasks: Array }

  connect() {
    this.clickOutside = this.clickOutside.bind(this)
    document.addEventListener("mousedown", this.clickOutside)

    // Store direct references before we move elements to body
    this._dropdown = this.hasDropdownTarget ? this.dropdownTarget : null
    this._list = this.hasListTarget ? this.listTarget : null

    // The description input is the ONLY way to attach a task (there is no task
    // <select> any more), so the list has to be ready on every page load —
    // including a Turbo navigation, which reconnects this controller.
    this.loadTasksForCurrentProject()
  }

  disconnect() {
    document.removeEventListener("mousedown", this.clickOutside)
    if (this._dropdown && this._dropdown.parentElement === document.body) {
      this._dropdown.remove()
    }
  }

  // The picked project changed: its tasks are a different set, and whatever was
  // attached belongs to the old project, so drop it.
  async projectChanged(event) {
    this.tasksValue = []
    this.clearTask()

    const projectId = event.target.value
    if (!projectId) return

    this.tasksValue = await fetchTasks(projectId)
  }

  async loadTasksForCurrentProject() {
    const form = this.element.closest("form") || this.element
    const projectSelect = form.querySelector("select[name*='project_id']")
    if (!projectSelect || !projectSelect.value) return

    this.tasksValue = await fetchTasks(projectSelect.value)
  }

  focus() {
    if (this._justSelected) return
    if (this.tasksValue.length === 0) return
    this.renderList()
    this.show()
  }

  filter() {
    // Emptying the description detaches the task — without the old <select>
    // there is no other way to undo a pick.
    if (this.inputTarget.value.trim() === "") this.clearTask()
    if (this.tasksValue.length === 0) return
    this.renderList(this.inputTarget.value)
    this.show()
  }

  clearTask() {
    if (this.hasTaskIdTarget) this.taskIdTarget.value = ""
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

  keydown(event) {
    if (event.key === "Escape") {
      this.hide()
      event.preventDefault()
    }
  }
}
