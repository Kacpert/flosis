import { Controller } from "@hotwired/stimulus"

// Generic modal for the Clar workshop shell — replaces per-feature modal
// wiring. The controller sits on a wrapper containing one or more triggers
// (e.g. an entry card with data-action="clar-modal#open") and one or more
// modal overlays (each marked data-clar-modal-target="panel", starts
// .hidden). A trigger with no data-clar-modal-id-param opens the first/only
// panel. A trigger with data-clar-modal-id-param="foo" opens the panel whose
// data-clar-modal-panel-id-value is "foo" — this lets several entry cards
// share one controller scope (see the Create Tasks page: "New idea" opens
// the untagged panel, "Existing Jira task" opens the "jira-picker" panel).
// Backdrop click closes; clicks on the panel itself don't bubble to the
// backdrop; Escape closes; body scroll is locked while open.
export default class extends Controller {
  static targets = ["panel"]

  connect() {
    this.boundKeydown = this.handleKeydown.bind(this)
  }

  disconnect() {
    document.removeEventListener("keydown", this.boundKeydown)
    document.body.style.overflow = ""
  }

  open(event) {
    if (event) event.preventDefault()
    const panel = this.resolvePanel(event)
    if (!panel) return
    // Close any other panel in this scope first — only one modal open at a
    // time (the Configuration page has several manage modals under one
    // controller; without this they'd stack on top of each other).
    this.panelTargets.forEach((p) => { if (p !== panel) p.classList.add("hidden") })
    panel.classList.remove("hidden")
    document.addEventListener("keydown", this.boundKeydown)
    document.body.style.overflow = "hidden"
  }

  close(event) {
    // A click that came from inside the panel isn't a backdrop click — see
    // stopPropagation below. Close buttons still work: their own action fires
    // earlier in the bubble, before the panel marks the event.
    if (event && event.clarInsidePanel) return

    this.panelTargets.forEach((panel) => panel.classList.add("hidden"))
    document.removeEventListener("keydown", this.boundKeydown)
    document.body.style.overflow = ""
  }

  // Marks the click as "inside the panel" instead of calling
  // event.stopPropagation(). Stopping propagation here also stopped the click
  // reaching Turbo's document-level listener, which quietly turned every link
  // inside a modal into a native full-page navigation — that's why the Jira
  // browser's board tabs escaped the modal, and why the developer-report modal
  // needed clar-frame-src to work around it.
  stopPropagation(event) {
    event.clarInsidePanel = true
  }

  handleKeydown(event) {
    if (event.key === "Escape") this.close()
  }

  resolvePanel(event) {
    const id = event && event.params && event.params.id
    if (!id) return this.panelTargets[0]
    return this.panelTargets.find((panel) => panel.dataset.clarModalPanelIdValue === id) || this.panelTargets[0]
  }
}
