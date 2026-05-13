import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["overlay", "content", "versionSelect", "copyBtn"]
  static values = { fetchUrl: String }

  connect() {
    this.drafts = []
    this.currentIndex = 0
  }

  async open() {
    this.overlayTarget.style.display = "flex"
    document.body.style.overflow = "hidden"
    await this.loadDrafts()
  }

  close() {
    this.overlayTarget.style.display = "none"
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

  selectVersion(event) {
    this.currentIndex = parseInt(event.target.value, 10)
    this.renderCurrent()
  }

  async copy() {
    const draft = this.drafts[this.currentIndex]
    if (!draft) return
    try {
      await navigator.clipboard.writeText(draft.content)
      const original = this.copyBtnTarget.textContent
      this.copyBtnTarget.textContent = "Copied!"
      setTimeout(() => { this.copyBtnTarget.textContent = original }, 1500)
    } catch (e) {
      this.copyBtnTarget.textContent = "Copy failed"
    }
  }

  async loadDrafts() {
    this.contentTarget.innerHTML = '<div style="color: var(--color-outline); text-align: center; padding: 2rem;">Loading…</div>'
    try {
      const res = await fetch(this.fetchUrlValue, { headers: { Accept: "application/json" } })
      const data = await res.json()
      this.drafts = data.drafts || []
      this.renderSelect()
      if (this.drafts.length === 0) {
        this.contentTarget.innerHTML = '<div style="color: var(--color-outline); text-align: center; padding: 2rem;">No AI-refined draft yet. Open a chat and ask Claude to draft the ticket.</div>'
        this.copyBtnTarget.disabled = true
        this.copyBtnTarget.style.opacity = "0.5"
      } else {
        this.copyBtnTarget.disabled = false
        this.copyBtnTarget.style.opacity = "1"
        this.currentIndex = 0
        this.renderCurrent()
      }
    } catch (e) {
      this.contentTarget.innerHTML = '<div style="color: var(--color-error); text-align: center; padding: 2rem;">Failed to load drafts.</div>'
    }
  }

  renderSelect() {
    if (this.drafts.length === 0) {
      this.versionSelectTarget.innerHTML = '<option>—</option>'
      this.versionSelectTarget.disabled = true
      return
    }
    this.versionSelectTarget.disabled = false
    this.versionSelectTarget.innerHTML = this.drafts.map((d, i) =>
      `<option value="${i}">${i === 0 ? "Latest — " : ""}${this.escape(d.created_at_display)}</option>`
    ).join("")
  }

  renderCurrent() {
    const draft = this.drafts[this.currentIndex]
    if (!draft) return
    this.contentTarget.innerHTML = this.renderMarkdown(draft.content)
  }

  escape(s) {
    return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;")
  }

  renderMarkdown(text) {
    const escape = (s) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;")

    // Fenced code blocks
    const codeBlocks = []
    let src = text.replace(/```(\w*)\n([\s\S]*?)```/g, (_m, _lang, code) => {
      codeBlocks.push(`<pre><code>${escape(code.replace(/\n$/, ""))}</code></pre>`)
      return ` CODEBLOCK${codeBlocks.length - 1} `
    })

    src = escape(src)
    const lines = src.split("\n")
    const out = []
    let inUl = false
    let inOl = false
    let paraBuf = []

    const flushPara = () => {
      if (paraBuf.length) { out.push(`<p>${paraBuf.join(" ")}</p>`); paraBuf = [] }
    }
    const closeLists = () => {
      if (inUl) { out.push("</ul>"); inUl = false }
      if (inOl) { out.push("</ol>"); inOl = false }
    }

    for (const line of lines) {
      if (/^\s*$/.test(line)) { flushPara(); closeLists(); continue }
      let m
      if ((m = line.match(/^(#{1,6})\s+(.*)$/))) {
        flushPara(); closeLists()
        out.push(`<h${m[1].length}>${this.inline(m[2])}</h${m[1].length}>`); continue
      }
      if ((m = line.match(/^\s*[-*]\s+\[( |x|X)\]\s+(.*)$/))) {
        // Checkbox list item
        flushPara()
        if (inOl) { out.push("</ol>"); inOl = false }
        if (!inUl) { out.push('<ul style="list-style: none; padding-left: 0;">'); inUl = true }
        const checked = m[1].toLowerCase() === "x"
        out.push(`<li><input type="checkbox" disabled${checked ? " checked" : ""} style="margin-right: 0.5rem;">${this.inline(m[2])}</li>`)
        continue
      }
      if ((m = line.match(/^\s*[-*]\s+(.*)$/))) {
        flushPara()
        if (inOl) { out.push("</ol>"); inOl = false }
        if (!inUl) { out.push("<ul>"); inUl = true }
        out.push(`<li>${this.inline(m[1])}</li>`); continue
      }
      if ((m = line.match(/^\s*\d+\.\s+(.*)$/))) {
        flushPara()
        if (inUl) { out.push("</ul>"); inUl = false }
        if (!inOl) { out.push("<ol>"); inOl = true }
        out.push(`<li>${this.inline(m[1])}</li>`); continue
      }
      closeLists()
      paraBuf.push(this.inline(line))
    }
    flushPara(); closeLists()
    let html = out.join("")
    html = html.replace(/ CODEBLOCK(\d+) /g, (_m, i) => codeBlocks[parseInt(i, 10)])
    return html
  }

  inline(s) {
    let h = s
    h = h.replace(/`([^`]+)`/g, "<code>$1</code>")
    h = h.replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>")
    h = h.replace(/(^|[^*])\*([^*\s][^*]*?)\*(?!\*)/g, "$1<em>$2</em>")
    h = h.replace(/\[([^\]]+)\]\(([^)\s]+)\)/g, '<a href="$2" target="_blank" rel="noopener">$1</a>')
    return h
  }
}
