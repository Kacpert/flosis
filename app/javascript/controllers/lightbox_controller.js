import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["overlay", "image", "caption"]

  open(event) {
    const src = event.params.src
    const caption = event.params.caption
    if (!src) return
    this.imageTarget.src = src
    this.imageTarget.alt = caption || ""
    this.captionTarget.textContent = caption || ""
    this.overlayTarget.style.display = "flex"
    document.body.style.overflow = "hidden"
  }

  close() {
    this.overlayTarget.style.display = "none"
    this.imageTarget.src = ""
    document.body.style.overflow = ""
  }

  handleKeydown(event) {
    if (event.key === "Escape" && this.overlayTarget.style.display === "flex") {
      this.close()
    }
  }

  stopPropagation(event) {
    event.stopPropagation()
  }
}
