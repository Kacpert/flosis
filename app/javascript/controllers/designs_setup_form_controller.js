import { Controller } from "@hotwired/stimulus"

// The Designs setup form's rows (Workshop Designs v2): app repositories and
// contexts are added from a template and removed in place.
export default class extends Controller {
  static targets = ["repos", "contexts", "repoTemplate", "contextTemplate"]

  addRepo() {
    this.add(this.reposTarget, this.repoTemplateTarget)
  }

  addContext() {
    this.add(this.contextsTarget, this.contextTemplateTarget)
  }

  remove(event) {
    event.currentTarget.closest("[data-designs-setup-form-row]")?.remove()
  }

  add(list, template) {
    const index = `n${Date.now()}`
    list.insertAdjacentHTML("beforeend", template.innerHTML.replaceAll("NEW_INDEX", index))
  }
}
