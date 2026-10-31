import { Controller } from "@hotwired/stimulus"

// The Designs screen's contexts. Each dimension has one active value, and
// picking a pill makes it that dimension's: the preview, the "Open in new tab"
// link and the page's own address all get the new ?ctx=. The address keeps it
// for the screen's refresh when a turn ends (Ruling P2-R27), and the server
// checks it against the dimensions it knows.
//
// Dimensions are told apart by position, as the server reads them back: the
// ids are Claude's and may repeat.
export default class extends Controller {
  static targets = ["frame", "open", "pill"]
  static values = { base: String, ctx: Array }

  pick(event) {
    const pill = event.currentTarget
    const ctx = [...this.ctxValue]
    ctx[Number(pill.dataset.dimension)] = pill.dataset.value
    this.ctxValue = ctx

    this.pillTargets
      .filter((other) => other.dataset.dimension === pill.dataset.dimension)
      .forEach((other) => other.classList.toggle("clar-chip-active", other === pill))

    const link = ctx.length ? `${this.baseValue}?ctx=${ctx.join(",")}` : this.baseValue
    this.frameTarget.src = link
    if (this.hasOpenTarget) this.openTarget.href = link

    const page = new URL(window.location.href)
    page.searchParams.set("ctx", ctx.join(","))
    window.history.replaceState(window.history.state, "", page)
  }

  // Contexts are made by Claude, on request: the pill starts the request.
  askForContext() {
    const composer = document.getElementById("designs-composer")
    if (!composer) return

    composer.value = "Add a context: "
    composer.focus()
    composer.setSelectionRange(composer.value.length, composer.value.length)
  }
}
