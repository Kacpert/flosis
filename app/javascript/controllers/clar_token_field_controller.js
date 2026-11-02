import { Controller } from "@hotwired/stimulus"

// Write-only masked credential field (GitHub access token, Figma token):
// blank means "keep the current value" on submit. "Rotate" just clears the
// field and focuses it so the admin can paste a new value.
export default class extends Controller {
  static targets = ["input"]

  rotate() {
    this.inputTarget.value = ""
    this.inputTarget.focus()
  }
}
