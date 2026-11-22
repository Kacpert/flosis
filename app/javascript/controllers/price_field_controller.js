import { Controller } from "@hotwired/stimulus"

// Models & prices (SCRUM-70): a typed price is saved the moment its field is
// left — if it changed — and the row is marked by hand on the next load.
export default class extends Controller {
  remember(event) {
    event.target.dataset.before = event.target.value
  }

  async save(event) {
    const input = event.target
    if (input.value === input.dataset.before) return

    const token = document.querySelector("meta[name=csrf-token]")?.content
    const response = await fetch(input.dataset.url, {
      method: "PATCH",
      headers: { "Content-Type": "application/json", "X-CSRF-Token": token, "Accept": "application/json" },
      body: JSON.stringify({ field: input.name, value: input.value })
    })
    input.dataset.before = input.value
    input.classList.toggle("!border-[color:var(--danger)]", !response.ok)
  }
}
