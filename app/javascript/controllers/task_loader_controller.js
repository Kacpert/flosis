import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  async load(event) {
    const projectId = event.target.value
    const taskSelect = this.element.closest("form").querySelector("select[name*='task_id']")
    if (!taskSelect) return

    if (!projectId) {
      taskSelect.innerHTML = '<option value="">No task</option>'
      return
    }

    try {
      const response = await fetch(`/projects/${projectId}/tasks_list`)
      if (response.ok) {
        taskSelect.innerHTML = await response.text()
      }
    } catch (e) {
      // silently fail
    }
  }
}
