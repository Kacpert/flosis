import { Controller } from "@hotwired/stimulus"

// Images for a design thread's next message (Kacper, 2026-11-19): the
// paperclip, a drop anywhere on the page, or a paste into the box. They wait
// as thumbnails above it and go with the message, in its images[] field; the
// turn reads them. PNG, JPG, GIF or WebP, up to 10 MB each and 10 a message.
// A file dropped on the page never opens in the tab, composer or not.
const TYPES = [ "image/png", "image/jpeg", "image/gif", "image/webp" ]
const LIMIT = 10 * 1024 * 1024

export default class extends Controller {
  static targets = [ "input", "previews", "dropHint" ]

  connect() {
    this.files = []
  }

  pick() {
    if (this.hasInputTarget) this.inputTarget.click()
  }

  // The picker's choice replaces the field's files: the earlier ones are put back.
  picked() {
    this.add([ ...this.inputTarget.files ])
  }

  dragOver(event) {
    if (!event.dataTransfer?.types?.includes("Files")) return
    event.preventDefault()
    if (this.hasInputTarget && this.hasDropHintTarget) this.dropHintTarget.classList.replace("hidden", "flex")
  }

  dragLeave(event) {
    if (event.relatedTarget && this.element.contains(event.relatedTarget)) return
    if (this.hasDropHintTarget) this.dropHintTarget.classList.replace("flex", "hidden")
  }

  drop(event) {
    if (!event.dataTransfer?.files?.length) return
    event.preventDefault()
    if (this.hasDropHintTarget) this.dropHintTarget.classList.replace("flex", "hidden")
    if (this.hasInputTarget) this.add([ ...event.dataTransfer.files ])
  }

  paste(event) {
    const files = [ ...(event.clipboardData?.files || []) ].filter((file) => file.type.startsWith("image/"))
    if (files.length === 0) return
    event.preventDefault()
    this.add(files)
  }

  add(files) {
    let refused = 0
    for (const file of files) {
      if (!TYPES.includes(file.type) || file.size > LIMIT || this.files.length >= 10) refused += 1
      else this.files.push(file)
    }
    this.sync()
    this.render(refused ? "Only PNG, JPG, GIF or WebP images, up to 10 MB each and 10 a message." : null)
  }

  remove(index) {
    this.files.splice(index, 1)
    this.sync()
    this.render()
  }

  sync() {
    const transfer = new DataTransfer()
    this.files.forEach((file) => transfer.items.add(file))
    this.inputTarget.files = transfer.files
  }

  render(note = null) {
    if (!this.hasPreviewsTarget) return
    const box = this.previewsTarget
    box.innerHTML = ""
    this.files.forEach((file, index) => {
      const item = document.createElement("div")
      item.className = "relative"
      const img = document.createElement("img")
      img.src = URL.createObjectURL(file)
      img.alt = file.name
      img.style.cssText = "height:52px;width:auto;max-width:110px;object-fit:cover;border-radius:8px;border:1px solid var(--border);"
      const remove = document.createElement("button")
      remove.type = "button"
      remove.textContent = "×"
      remove.title = "Remove"
      remove.setAttribute("aria-label", `Remove ${file.name}`)
      remove.style.cssText = "position:absolute;top:-7px;right:-7px;width:20px;height:20px;border-radius:50%;border:1px solid var(--border);background:var(--surface);color:var(--text);font-size:13px;line-height:1;cursor:pointer;"
      remove.addEventListener("click", () => this.remove(index))
      item.append(img, remove)
      box.appendChild(item)
    })
    if (note) {
      const line = document.createElement("div")
      line.className = "w-full text-[11.5px] clar-text-warn"
      line.textContent = note
      box.appendChild(line)
    }
    box.classList.toggle("hidden", box.children.length === 0)
    box.classList.toggle("flex", box.children.length > 0)
  }
}
