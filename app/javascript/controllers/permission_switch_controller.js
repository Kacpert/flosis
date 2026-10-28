import { Controller } from "@hotwired/stimulus"

// Flips one permission and swaps the whole row back in, because the role name
// beside the switches is derived from them and would otherwise go stale.
export default class extends Controller {
  static values = { url: String, permission: String }

  async toggle(event) {
    const button = event.currentTarget
    if (button.disabled) return

    const next = button.getAttribute("aria-checked") !== "true"
    button.disabled = true

    const body = new FormData()
    body.append("permission", this.permissionValue)
    body.append("value", next ? "1" : "0")
    body.append("_method", "patch")

    const response = await fetch(this.urlValue, {
      method: "POST",
      body,
      headers: {
        "Accept": "text/vnd.turbo-stream.html",
        "X-CSRF-Token": document.querySelector("meta[name=csrf-token]")?.content
      }
    })

    if (response.ok) {
      Turbo.renderStreamMessage(await response.text())
    } else {
      button.disabled = false
    }
  }
}
