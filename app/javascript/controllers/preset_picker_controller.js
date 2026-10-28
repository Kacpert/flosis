import { Controller } from "@hotwired/stimulus"

// The role buttons in the invite dialogs are presets and nothing more: they
// set the six switches, and the switches are what gets submitted. Touching one
// afterwards is expected — the role name is read back off the switches, so a
// tuned set simply lands as "Custom".
//
// The presets arrive as a value rather than a literal here, because
// PermissionPreset::PRESETS is the only copy the product has of what each role
// name grants; a second copy in JavaScript would drift the first time one of
// them changes.
export default class extends Controller {
  static targets = ["switch", "value", "button"]
  static values = { presets: Object }

  connect() {
    this.apply(this.valueTarget.value)
  }

  pick(event) {
    this.valueTarget.value = event.params.name
    this.apply(event.params.name)
    this.buttonTargets.forEach((button) => {
      button.classList.toggle("clar-btn-primary", button.dataset.presetPickerNameParam === event.params.name)
    })
  }

  apply(preset) {
    const granted = this.presetsValue[preset] || []
    this.switchTargets.forEach((element) => {
      this.set(element, granted.includes(element.dataset.permission))
    })
  }

  toggle(event) {
    const element = event.currentTarget
    this.set(element, element.getAttribute("aria-checked") !== "true")
  }

  // Each switch carries a hidden input so the form submits the actual state,
  // not the preset the person started from. clar-toggle-sm paints its track
  // from the PARENT's aria-checked, so there is no class to toggle here.
  set(element, on) {
    element.setAttribute("aria-checked", on)
    let input = element.nextElementSibling
    if (!input || input.tagName !== "INPUT") {
      input = document.createElement("input")
      input.type = "hidden"
      element.after(input)
    }
    input.name = `permissions[${element.dataset.permission}]`
    input.value = on ? "1" : "0"
  }
}
