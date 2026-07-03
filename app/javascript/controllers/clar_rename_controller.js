import { Controller } from "@hotwired/stimulus"

// Inline rename of the workspace H1 (pencil click -> input swap). Enter or
// blur saves via a fetch PATCH to the idea's show URL; Escape cancels and
// reverts. On success, updates the H1 text optimistically and dispatches a
// window "clar:toast" event (picked up by clar_toast_controller.js).
export default class extends Controller {
  static targets = ["display", "input", "pencil", "hint"]
  static values = { url: String, name: String }

  edit() {
    this.inputTarget.value = this.nameValue
    this.displayTarget.classList.add("hidden")
    this.inputTarget.classList.remove("hidden")
    this.inputTarget.focus()
    this.inputTarget.select()
  }

  keydown(event) {
    if (event.key === "Enter") {
      event.preventDefault()
      this.save()
    } else if (event.key === "Escape") {
      event.preventDefault()
      this.cancel()
    }
  }

  cancel() {
    this.inputTarget.value = this.nameValue
    this.showDisplay()
  }

  save() {
    const name = this.inputTarget.value.trim()

    if (!name || name === this.nameValue) {
      this.cancel()
      return
    }

    const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content

    fetch(this.urlValue, {
      method: "PATCH",
      headers: {
        "Content-Type": "application/json",
        "Accept": "application/json",
        "X-CSRF-Token": csrfToken,
      },
      body: JSON.stringify({ idea: { name } }),
    })
      .then((response) => {
        if (!response.ok) throw new Error("rename failed")
        return response.json()
      })
      .then((data) => {
        this.nameValue = data.name
        this.displayTarget.textContent = data.name
        this.showDisplay()
        window.dispatchEvent(new CustomEvent("clar:toast", { detail: { message: "Renamed" } }))
      })
      .catch(() => {
        this.cancel()
      })
  }

  showDisplay() {
    this.inputTarget.classList.add("hidden")
    this.displayTarget.classList.remove("hidden")
  }
}
