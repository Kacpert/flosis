import { Controller } from "@hotwired/stimulus"

// Rich-text editing of brief/description versions (Task 5.2). Swaps the
// document panel's body + footer for a contenteditable editor (toolbar via
// document.execCommand, exactly like the redesign.html mockup) with two save
// paths:
//   - "Save v{n} in place"   -> PATCH the same version row (origin unchanged,
//                               edited_at stamped server-side).
//   - "Save as new version"  -> POST a new origin:"manual" row, which the
//                               server makes current immediately.
// Content is sent as raw HTML (content_html) — the server stores it as-is
// and sanitizes on render; no markdown conversion happens here.
export default class extends Controller {
  static targets = ["body", "footer", "editButton"]
  static values = {
    kind: String,
    version: Number,
    isUser: Boolean,
    createUrl: String,
    updateUrl: String,
    redirectUrl: String
  }

  connect() {
    this.savedBodyHtml = null
    this.savedFooterHtml = null
  }

  startEdit() {
    const proseEl = this.bodyTarget.querySelector("#clar-document-body")
    const seedHtml = proseEl ? proseEl.innerHTML : ""

    this.savedBodyHtml = this.bodyTarget.innerHTML
    this.savedFooterHtml = this.footerTarget.innerHTML

    this.bodyTarget.innerHTML = this.editorMarkup(seedHtml)
    this.footerTarget.innerHTML = this.footerMarkup()

    this.editorEl = this.bodyTarget.querySelector("[data-clar-editor-surface]")
    this.wireToolbar()
    this.footerTarget.querySelector("[data-clar-editor-cancel]").addEventListener("click", () => this.cancelEdit())
    this.footerTarget.querySelector("[data-clar-editor-save-in-place]").addEventListener("click", () => this.saveInPlace())
    this.footerTarget.querySelector("[data-clar-editor-save-as-new]").addEventListener("click", () => this.saveAsNew())

    if (this.hasEditButtonTarget) this.editButtonTarget.style.display = "none"
  }

  cancelEdit() {
    this.bodyTarget.innerHTML = this.savedBodyHtml
    this.footerTarget.innerHTML = this.savedFooterHtml
    if (this.hasEditButtonTarget) this.editButtonTarget.style.display = ""
  }

  editorMarkup(seedHtml) {
    const hint = `Editing v${this.versionValue}${this.isUserValue ? " · user description" : ""} — save in place, or save as a new version.`
    return `
      <div class="flex flex-col gap-2.5">
        <div class="text-[11.5px] clar-text-faint">${hint}</div>
        <div class="flex flex-wrap gap-[2px] p-1.5 bg-[var(--surface-2)] border clar-divider rounded-[9px]" data-clar-editor-toolbar>
          <button type="button" data-cmd="bold" title="Bold" class="clar-editor-tool-btn"><svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M6 4h8a4 4 0 0 1 0 8H6zM6 12h9a4 4 0 0 1 0 8H6z"/></svg></button>
          <button type="button" data-cmd="italic" title="Italic" class="clar-editor-tool-btn"><svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M19 4h-9M14 20H5M15 4L9 20"/></svg></button>
          <button type="button" data-cmd="insertUnorderedList" title="Bullet list" class="clar-editor-tool-btn"><svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M8 6h13M8 12h13M8 18h13M3 6h.01M3 12h.01M3 18h.01"/></svg></button>
          <button type="button" data-cmd="insertOrderedList" title="Numbered list" class="clar-editor-tool-btn"><svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M10 6h11M10 12h11M10 18h11M4 6h1v4M4 10h2M6 18H4l2-2.5V15H4"/></svg></button>
          <span class="w-px clar-divider mx-1 my-[3px]"></span>
          <button type="button" data-cmd="formatBlock" data-val="&lt;h4&gt;" title="Heading" class="clar-editor-tool-btn font-extrabold">H</button>
          <button type="button" data-cmd="formatBlock" data-val="&lt;p&gt;" title="Paragraph" class="clar-editor-tool-btn font-semibold">¶</button>
          <button type="button" data-cmd="formatBlock" data-val="&lt;pre&gt;" title="Code block" class="clar-editor-tool-btn"><svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M16 18l6-6-6-6M8 6l-6 6 6 6"/></svg></button>
          <button type="button" data-cmd="createLink" title="Link" class="clar-editor-tool-btn"><svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M10 13a5 5 0 0 0 7 0l3-3a5 5 0 0 0-7-7l-1 1M14 11a5 5 0 0 0-7 0l-3 3a5 5 0 0 0 7 7l1-1"/></svg></button>
        </div>
        <div class="clar-editor clar-prose" contenteditable="true" data-clar-editor-surface>${seedHtml}</div>
      </div>
    `
  }

  footerMarkup() {
    return `
      <div class="flex flex-col gap-2.5">
        <button type="button" class="clar-btn clar-btn-ai clar-btn-block" data-clar-editor-save-as-new>Save as new version</button>
        <div class="flex gap-2.5">
          <button type="button" class="clar-btn flex-1" data-clar-editor-cancel>Cancel</button>
          <button type="button" class="clar-btn flex-1" data-clar-editor-save-in-place>
            <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M19 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h11l5 5v11a2 2 0 0 1-2 2zM17 21v-8H7v8M7 3v5h8"/></svg>
            Save v${this.versionValue} in place
          </button>
        </div>
      </div>
    `
  }

  wireToolbar() {
    this.bodyTarget.querySelectorAll("[data-clar-editor-toolbar] [data-cmd]").forEach(btn => {
      btn.addEventListener("mousedown", (e) => {
        e.preventDefault()
        const cmd = btn.dataset.cmd
        if (cmd === "createLink") {
          const url = prompt("Link URL")
          if (url) this.exec(cmd, url)
        } else if (cmd === "formatBlock") {
          this.exec(cmd, btn.dataset.val)
        } else {
          this.exec(cmd)
        }
      })
    })
  }

  exec(cmd, val) {
    document.execCommand(cmd, false, val)
    if (this.editorEl) this.editorEl.focus()
  }

  async saveInPlace() {
    await this.submit(this.updateUrlValue, "PATCH")
  }

  async saveAsNew() {
    await this.submit(this.createUrlValue, "POST")
  }

  async submit(url, method) {
    const contentHtml = this.editorEl ? this.editorEl.innerHTML : ""
    try {
      const response = await fetch(url, {
        method,
        headers: {
          "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content,
          "Content-Type": "application/json",
          "Accept": "text/html"
        },
        body: JSON.stringify({ kind: this.kindValue, content_html: contentHtml })
      })
      if (response.ok || response.redirected) {
        window.location.href = response.url || this.redirectUrlValue
      } else {
        alert("Couldn't save — please try again.")
      }
    } catch (e) {
      alert("Couldn't save — please try again.")
    }
  }
}
