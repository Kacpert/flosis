import { Controller } from "@hotwired/stimulus"

// "Attach inspiration": picking files sends them straight away (their form is
// the thread's attach form, outside the composer).
export default class extends Controller {
  submit() {
    if (this.element.files.length) this.element.form.requestSubmit()
  }
}
