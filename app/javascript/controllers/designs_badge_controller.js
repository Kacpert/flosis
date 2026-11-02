import { Controller } from "@hotwired/stimulus"

// A pipeline row's Designs badge sits inside the row's own link, so it opens
// its thread itself rather than following the row.
export default class extends Controller {
  static values = { url: String }

  open(event) {
    event.preventDefault()
    event.stopPropagation()
    window.Turbo.visit(this.urlValue)
  }
}
