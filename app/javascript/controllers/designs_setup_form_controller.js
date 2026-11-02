import { Controller } from "@hotwired/stimulus"

// The Designs setup form's rows (Workshop Designs v2): app repositories and
// contexts are added from a template and removed in place.
export default class extends Controller {
  static targets = ["repos", "contexts", "repoTemplate", "contextTemplate", "hint"]

  connect() {
    this.check()
  }

  // The footer says what is missing until the designs repository, one app
  // repository and one context with its URL and login are filled in.
  check() {
    if (!this.hasHintTarget) return
    const value = (name) => this.element.querySelector(`[name="${name}"]`)?.value.trim()
    const any = (pattern) => [...this.element.querySelectorAll("input")].some((input) => pattern.test(input.name) && input.value.trim())
    const contexts = [...this.contextsTarget.querySelectorAll("[data-designs-setup-form-row]")].some((row) =>
      ["name", "url", "login"].every((field) => row.querySelector(`[name$="[${field}]"]`)?.value.trim()))
    const ready = !!value("repo") && any(/^repos\[[^\]]+\]\[url\]$/) && contexts
    this.hintTarget.textContent = ready ? this.hintTarget.dataset.ready : this.hintTarget.dataset.incomplete
  }

  addRepo() {
    this.add(this.reposTarget, this.repoTemplateTarget)
  }

  addContext() {
    this.add(this.contextsTarget, this.contextTemplateTarget)
  }

  remove(event) {
    event.currentTarget.closest("[data-designs-setup-form-row]")?.remove()
    this.check()
  }

  add(list, template) {
    const index = `n${Date.now()}`
    list.insertAdjacentHTML("beforeend", template.innerHTML.replaceAll("NEW_INDEX", index))
  }
}
