import { Controller } from "@hotwired/stimulus"

// Images for a design thread's next message (Kacper, 2026-11-19): the
// paperclip, a drop anywhere on the page, or a paste into the box. They wait
// as thumbnails above it and go with the message, in its images[] field; the
// turn reads them. PNG, JPG, GIF or WebP, up to 10 MB each and 10 a message.
// A file dropped on the page never opens in the tab, composer or not.
//
// Switching the role, the mode or the screen reloads the page, so the images
// are kept for the thread in this tab until the message is sent, as its text
// is (Kacper, 2026-11-23). They are files, too big for sessionStorage: they
// wait in IndexedDB under this tab's id, and a tab closed with images waiting
// leaves them for KEPT at most.
const TYPES = [ "image/png", "image/jpeg", "image/gif", "image/webp" ]
const LIMIT = 10 * 1024 * 1024
const DATABASE = "flosis-designs"
const STORE = "waiting-images"
const KEPT = 2 * 24 * 60 * 60 * 1000

export default class extends Controller {
  static targets = [ "input", "previews", "dropHint" ]

  // Before connect: Stimulus tells of the targets first.
  initialize() {
    this.files = []
    this.sent = this.sent.bind(this)
  }

  connect() {
    waiting("readwrite", (store) => prune(store)).catch(() => {})
  }

  inputTargetConnected(input) {
    input.form?.addEventListener("submit", this.sent)
    this.restore(input)
  }

  inputTargetDisconnected(input) {
    input.form?.removeEventListener("submit", this.sent)
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
    this.keep()
    this.render(refused ? "Only PNG, JPG, GIF or WebP images, up to 10 MB each and 10 a message." : null)
  }

  remove(index) {
    this.files.splice(index, 1)
    this.sync()
    this.keep()
    this.render()
  }

  // What waited before the page reloaded, unless images were added meanwhile.
  async restore(input) {
    const key = keyFor(input)
    if (!key) return
    let kept
    try {
      kept = await waiting("readonly", (store) => store.get(key))
    } catch {
      return
    }
    if (!kept?.files?.length || this.files.length || !input.isConnected || input !== this.inputTarget) return
    this.files = kept.files
    this.sync()
    this.render()
  }

  keep() {
    const key = this.hasInputTarget && keyFor(this.inputTarget)
    if (!key) return
    const files = [ ...this.files ]
    waiting("readwrite", (store) => (files.length ? store.put({ files, at: Date.now() }, key) : store.delete(key))).catch(() => {})
  }

  sent() {
    const key = this.hasInputTarget && keyFor(this.inputTarget)
    if (key) waiting("readwrite", (store) => store.delete(key)).catch(() => {})
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

// The thread's images in this tab: the tab's id (sessionStorage, as the text's
// draft) and the input's draft key. Null when the tab cannot keep anything.
function keyFor(input) {
  const draft = input.dataset.draftKey
  if (!draft) return null
  try {
    let tab = sessionStorage.getItem("designs.tab")
    if (!tab) {
      tab = crypto.randomUUID?.() || Math.random().toString(36).slice(2)
      sessionStorage.setItem("designs.tab", tab)
    }
    return `${tab} ${draft}`
  } catch {
    return null
  }
}

// One transaction on the store of waiting images; resolves with the request's
// result once it is done.
function waiting(mode, work) {
  return new Promise((resolve, reject) => {
    const opening = indexedDB.open(DATABASE, 1)
    opening.onupgradeneeded = () => opening.result.createObjectStore(STORE)
    opening.onerror = () => reject(opening.error)
    opening.onsuccess = () => {
      const database = opening.result
      const transaction = database.transaction(STORE, mode)
      const request = work(transaction.objectStore(STORE))
      transaction.oncomplete = () => {
        database.close()
        resolve(request?.result)
      }
      transaction.onerror = transaction.onabort = () => {
        database.close()
        reject(transaction.error)
      }
    }
  })
}

// Images a closed tab left behind go after KEPT.
function prune(store) {
  const cursor = store.openCursor()
  cursor.onsuccess = () => {
    const entry = cursor.result
    if (!entry) return
    if (!(entry.value?.at > Date.now() - KEPT)) entry.delete()
    entry.continue()
  }
}
