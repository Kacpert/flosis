import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["modal", "content"]

  connect() {
    this.handleKeydown = this.handleKeydown.bind(this)
  }

  open(event) {
    if (event.target.closest("a")) return

    const taskUrl = event.currentTarget.dataset.taskUrl
    if (!taskUrl) return

    this.contentTarget.src = taskUrl
    this.modalTarget.classList.remove("hidden")
    document.addEventListener("keydown", this.handleKeydown)
    document.body.style.overflow = "hidden"
  }

  close() {
    this.modalTarget.classList.add("hidden")
    this.contentTarget.innerHTML = ""
    this.contentTarget.removeAttribute("src")
    document.removeEventListener("keydown", this.handleKeydown)
    document.body.style.overflow = ""
  }

  handleKeydown(event) {
    if (event.key === "Escape") {
      this.close()
    }
  }
}
