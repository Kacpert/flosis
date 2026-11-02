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

    // response.ok is not enough: fetch follows redirects, so an expired session
    // or a row the server refuses arrives as the 200 of whatever page it was
    // sent to. renderStreamMessage of an HTML page does nothing at all, and the
    // switch stayed disabled for the life of the page with no explanation.
    const stream = response.headers.get("content-type")?.includes("text/vnd.turbo-stream.html")

    if (response.ok && !response.redirected && stream) {
      Turbo.renderStreamMessage(await response.text())
      return
    }

    button.disabled = false
    // A redirect carries the reason as a flash, and only a real navigation
    // shows it — including the sign-in screen, which is the honest answer to a
    // session that ended while this page sat open.
    if (response.redirected) window.location.reload()
  }
}
