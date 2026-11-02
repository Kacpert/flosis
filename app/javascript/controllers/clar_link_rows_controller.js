import { Controller } from "@hotwired/stimulus"

// "Mark delivered" designs form (Task 5.3, _deliver_designs_modal.html.erb):
// adds a blank name/url row to the list. Removal is intentionally NOT handled
// client-side here — submitting the form with a blank url for a row drops
// that row server-side (Workshop::DesignRequestsController#normalize_links),
// which is how "remove a link" round-trips when the form is reopened.
export default class extends Controller {
  static targets = ["list", "row"]

  addRow() {
    const row = document.createElement("div")
    row.className = "flex gap-2 items-start"
    row.dataset.clarLinkRowsTarget = "row"
    row.innerHTML = `
      <input type="text" name="design_request[links][][name]" placeholder="Name (optional)" class="clar-input flex-1">
      <input type="text" name="design_request[links][][url]" placeholder="https://figma.com/…" class="clar-input clar-mono flex-[2]">
    `
    this.listTarget.appendChild(row)
  }
}
