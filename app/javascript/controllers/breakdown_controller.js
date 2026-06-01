import { Controller } from "@hotwired/stimulus"

// Drives the two-panel breakdown page:
//   left  — the rendered estimate + sub-task breakdown, with read-only version history
//   right — a Claude chat to refine it; each AI reply may carry a new version
//
// On connect: if a breakdown already exists, render the latest; otherwise
// auto-generate the first one. Refinements stream into the chat, and when the
// stream finishes we re-fetch the saved versions and re-render the left panel.
export default class extends Controller {
  static targets = ["panel", "versionSelect", "regenerateBtn", "chatMessages", "chatInput"]
  static values = {
    versionsUrl: String,
    createUrl: String,
    messageUrl: String,
    hasBreakdown: Boolean,
    hasSession: Boolean,
    currentUserName: { type: String, default: "" }
  }

  connect() {
    this.versions = []
    this.currentIndex = 0
    this.abortController = null
    this.boot()
  }

  disconnect() {
    this.abortIfStreaming()
  }

  async boot() {
    await this.loadVersions()
    if (this.hasSessionValue) {
      await this.loadChat()
    }
    if (this.versions.length > 0) {
      this.renderVersions()
      this.renderCurrent()
    } else {
      // No breakdown yet — generate the first one automatically.
      await this.generateInitial()
    }
  }

  // ---- left panel: versions & rendering ---------------------------------

  async loadVersions() {
    try {
      const res = await fetch(this.versionsUrlValue, { headers: { Accept: "application/json" } })
      const data = await res.json()
      this.versions = data.versions || []
    } catch (e) {
      this.versions = []
    }
  }

  renderVersions() {
    if (this.versions.length === 0) {
      this.versionSelectTarget.style.display = "none"
      this.regenerateBtnTarget.style.display = ""
      return
    }
    this.versionSelectTarget.style.display = ""
    this.regenerateBtnTarget.style.display = ""
    this.versionSelectTarget.innerHTML = this.versions.map((v, i) =>
      `<option value="${i}">${i === 0 ? "Latest" : `v${this.versions.length - i}`} — ${this.escape(v.created_at_display)}</option>`
    ).join("")
    this.versionSelectTarget.value = String(this.currentIndex)
  }

  selectVersion(event) {
    this.currentIndex = parseInt(event.target.value, 10)
    this.renderCurrent()
  }

  renderCurrent() {
    const version = this.versions[this.currentIndex]
    if (!version) return
    this.panelTarget.innerHTML = this.renderBreakdown(version.breakdown, this.currentIndex !== 0)
  }

  // Build the breakdown card from the parsed JSON object.
  renderBreakdown(b, isHistorical) {
    if (!b) return this.emptyState()

    const subtasks = Array.isArray(b.subtasks) ? b.subtasks : []
    const points = Number.isFinite(b.total_points) ? b.total_points : "—"
    const parts = []

    if (isHistorical) {
      parts.push(`<div class="bd-meta" style="font-style: italic;">Viewing an earlier version (read-only). Switch to “Latest” to keep refining.</div>`)
    }

    // Summary bar
    let summary = `<div class="bd-summary">
      <span class="bd-total"><span class="bd-total__points">${points}</span><span class="bd-total__label">points total</span></span>`
    if (b.needs_breakdown === false) {
      summary += `<span class="bd-badge">No breakdown needed</span>`
    } else {
      summary += `<span class="bd-meta">${subtasks.length} sub-task${subtasks.length === 1 ? "" : "s"}</span>`
    }
    summary += `</div>`
    parts.push(summary)

    // Warning
    if (b.warning) {
      parts.push(`<div class="bd-warning">
        <svg xmlns="http://www.w3.org/2000/svg" class="h-4 w-4" style="flex-shrink:0;margin-top:1px" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2"><path stroke-linecap="round" stroke-linejoin="round" d="M12 9v3.75m9-.75a9 9 0 11-18 0 9 9 0 0118 0zm-9 3.75h.008v.008H12v-.008z"/></svg>
        <span>${this.escape(b.warning)}</span>
      </div>`)
    }

    // Strategy
    if (b.strategy) {
      parts.push(`<div class="bd-strategy"><strong>Strategy.</strong> ${this.escape(b.strategy)}</div>`)
    }

    // Sub-tasks
    if (b.needs_breakdown === false || subtasks.length === 0) {
      if (b.needs_breakdown === false) {
        parts.push(`<div class="bd-meta">This task is small enough to take on as-is — no need to split it.</div>`)
      }
    } else {
      const ordered = [...subtasks].sort((a, c) => (a.order ?? 999) - (c.order ?? 999))
      const cards = ordered.map((st, idx) => {
        const order = Number.isFinite(st.order) ? st.order : idx + 1
        const deps = Array.isArray(st.depends_on) && st.depends_on.length > 0
          ? `<div class="bd-subtask__deps">Depends on: ${st.depends_on.map(d => this.escape(d)).join(", ")}</div>`
          : ""

        const ac = Array.isArray(st.acceptance_criteria) ? st.acceptance_criteria.filter(Boolean) : []
        const acBlock = ac.length > 0
          ? `<div class="bd-ac">
              <div class="bd-ac__label">Acceptance criteria</div>
              <ul class="bd-ac__list">${ac.map(c => `<li>${this.escape(c)}</li>`).join("")}</ul>
            </div>`
          : ""

        const links = Array.isArray(st.figma_links) ? st.figma_links.filter(l => l && this.safeUrl(l.url)) : []
        const figmaBlock = links.length > 0
          ? `<div class="bd-figma">
              ${links.map(l => `<a class="bd-figma__link" href="${l.url}" target="_blank" rel="noopener">
                <svg class="h-3.5 w-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2"><path stroke-linecap="round" stroke-linejoin="round" d="M13.5 6H5.25A2.25 2.25 0 003 8.25v10.5A2.25 2.25 0 005.25 21h10.5A2.25 2.25 0 0018 18.75V10.5m-10.5 6L21 3m0 0h-5.25M21 3v5.25"/></svg>
                ${this.escape(l.label || "Figma")}</a>`).join("")}
            </div>`
          : ""

        return `<div class="bd-subtask" data-open="false">
          <div class="bd-subtask__head" data-action="click->breakdown#toggleSubtask">
            <span class="bd-subtask__order">${order}</span>
            <span class="bd-subtask__title">${this.escape(st.title || "Untitled")}</span>
            <span class="bd-points">${Number.isFinite(st.points) ? st.points : "?"}</span>
            <svg class="bd-chevron h-4 w-4" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2"><path stroke-linecap="round" stroke-linejoin="round" d="M8.25 4.5l7.5 7.5-7.5 7.5"/></svg>
          </div>
          <div class="bd-subtask__body" style="display:none">
            <p>${this.escape(st.description || "(no description)")}</p>
            ${acBlock}
            ${figmaBlock}
            ${deps}
          </div>
        </div>`
      }).join("")
      parts.push(`<div class="space-y-3">${cards}</div>`)
    }

    // Copy-all
    parts.push(`<div style="padding-top:0.25rem">
      <button type="button" data-action="click->breakdown#copyAll"
        class="inline-flex items-center gap-1.5 text-xs px-3 py-1.5 rounded-lg transition-colors"
        style="background: var(--color-surface-container); color: var(--color-on-surface); border: 1px solid var(--color-outline-variant)">
        <svg xmlns="http://www.w3.org/2000/svg" class="h-4 w-4" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2"><path stroke-linecap="round" stroke-linejoin="round" d="M15.75 17.25v3.375c0 .621-.504 1.125-1.125 1.125h-9.75a1.125 1.125 0 01-1.125-1.125V7.875c0-.621.504-1.125 1.125-1.125H6.75a9.06 9.06 0 011.5.124m7.5 10.376h3.375c.621 0 1.125-.504 1.125-1.125V11.25c0-4.46-3.243-8.161-7.5-8.876a9.06 9.06 0 00-1.5-.124H9.375c-.621 0-1.125.504-1.125 1.125v3.5m7.5 10.375H9.375a1.125 1.125 0 01-1.125-1.125v-9.25m12 6.625v-1.875a3.375 3.375 0 00-3.375-3.375h-1.5a1.125 1.125 0 01-1.125-1.125v-1.5a3.375 3.375 0 00-3.375-3.375H9.75"/></svg>
        <span data-breakdown-target="copyLabel">Copy as text</span>
      </button>
    </div>`)

    return parts.join("")
  }

  toggleSubtask(event) {
    const card = event.currentTarget.closest(".bd-subtask")
    if (!card) return
    const body = card.querySelector(".bd-subtask__body")
    const open = card.dataset.open === "true"
    card.dataset.open = open ? "false" : "true"
    body.style.display = open ? "none" : "block"
  }

  async copyAll() {
    const version = this.versions[this.currentIndex]
    if (!version) return
    try {
      await navigator.clipboard.writeText(this.breakdownToText(version.breakdown))
      const label = this.element.querySelector('[data-breakdown-target="copyLabel"]')
      if (label) { const orig = label.textContent; label.textContent = "Copied!"; setTimeout(() => { label.textContent = orig }, 1500) }
    } catch (e) { /* clipboard unavailable */ }
  }

  breakdownToText(b) {
    if (!b) return ""
    const lines = []
    lines.push(`Estimate: ${b.total_points} points total`)
    if (b.strategy) lines.push(`Strategy: ${b.strategy}`)
    if (b.warning) lines.push(`⚠ ${b.warning}`)
    const subtasks = Array.isArray(b.subtasks) ? [...b.subtasks].sort((a, c) => (a.order ?? 999) - (c.order ?? 999)) : []
    subtasks.forEach((st, i) => {
      lines.push("")
      lines.push(`${st.order ?? i + 1}. [${st.points}] ${st.title}`)
      if (st.description) lines.push(`   ${st.description}`)
      if (Array.isArray(st.acceptance_criteria) && st.acceptance_criteria.length) {
        lines.push(`   Acceptance criteria:`)
        st.acceptance_criteria.forEach(c => lines.push(`     - ${c}`))
      }
      if (Array.isArray(st.figma_links) && st.figma_links.length) {
        st.figma_links.forEach(l => lines.push(`   Figma: ${l.label ? l.label + " — " : ""}${l.url}`))
      }
      if (Array.isArray(st.depends_on) && st.depends_on.length) lines.push(`   Depends on: ${st.depends_on.join(", ")}`)
    })
    return lines.join("\n")
  }

  emptyState() {
    return `<div class="flex flex-col items-center justify-center text-center" style="min-height: 240px; gap: 0.75rem; color: var(--color-on-surface-variant)">
      <p class="text-sm">No breakdown yet.</p>
      <button type="button" data-action="click->breakdown#regenerate"
        class="inline-flex items-center gap-1.5 text-sm px-4 py-2 rounded-lg"
        style="background: var(--color-primary); color: var(--color-on-primary)">Generate</button>
    </div>`
  }

  showGenerating() {
    this.panelTarget.innerHTML = `
      <div class="bd-skeleton" style="height: 56px;"></div>
      <div class="bd-skeleton" style="height: 40px; width: 70%;"></div>
      <div class="space-y-3">
        <div class="bd-skeleton" style="height: 52px;"></div>
        <div class="bd-skeleton" style="height: 52px;"></div>
        <div class="bd-skeleton" style="height: 52px;"></div>
      </div>
      <div class="text-sm" style="color: var(--color-on-surface-variant)">Estimating and breaking down the task…</div>`
  }

  // ---- generation & chat ------------------------------------------------

  async generateInitial() {
    this.showGenerating()
    this.chatMessagesTarget.innerHTML = ""
    const bubble = this.appendMessage("assistant", "")
    const textSpan = bubble.querySelector("[data-chat-text]")
    this.showThinking(textSpan)
    try {
      const response = await fetch(this.createUrlValue, { method: "POST", headers: this.headers() })
      const result = await this.consumeSSE(response, textSpan)
      if (result.error) { this.showError(result.error); this.panelTarget.innerHTML = this.emptyState(); return }
      this.hasSessionValue = true
      await this.refreshAfterStream()
    } catch (e) {
      this.showError("Failed to generate breakdown")
      this.panelTarget.innerHTML = this.emptyState()
    }
  }

  regenerate() {
    this.submitChat("Please regenerate the estimate and breakdown from scratch based on the current task description.")
  }

  async sendMessage(event) {
    event?.preventDefault()
    const content = this.chatInputTarget.value.trim()
    if (!content) return
    this.chatInputTarget.value = ""
    await this.submitChat(content)
  }

  async submitChat(content) {
    // No session yet (e.g. first generation failed) — generate instead.
    if (!this.hasSessionValue) { await this.generateInitial(); return }

    this.chatInputTarget.disabled = true
    this.appendMessage("user", content, this.currentUserNameValue || null)
    const bubble = this.appendMessage("assistant", "")
    const textSpan = bubble.querySelector("[data-chat-text]")
    this.showThinking(textSpan)
    this.showGenerating()
    this.abortController = new AbortController()
    try {
      const response = await fetch(this.messageUrlValue, {
        method: "POST",
        headers: { ...this.headers(), "Content-Type": "application/json" },
        body: JSON.stringify({ content }),
        signal: this.abortController.signal
      })
      await this.consumeSSE(response, textSpan)
      await this.refreshAfterStream()
    } catch (e) {
      if (e.name !== "AbortError") { this.hideThinking(textSpan); textSpan.textContent = "[Connection interrupted]" }
      this.renderCurrent()
    } finally {
      this.chatInputTarget.disabled = false
      this.chatInputTarget.focus()
      this.abortController = null
    }
  }

  // After a stream completes, reload versions; if a new one arrived, show it.
  async refreshAfterStream() {
    await this.loadVersions()
    this.currentIndex = 0
    this.renderVersions()
    if (this.versions.length > 0) {
      this.renderCurrent()
    } else {
      this.panelTarget.innerHTML = this.emptyState()
    }
  }

  async resetConversation() {
    if (!confirm("Reset this conversation? Saved breakdown versions are kept.")) return
    this.abortIfStreaming()
    try {
      await fetch(this.createUrlValue, { method: "DELETE", headers: this.headers() })
      this.hasSessionValue = false
      this.chatMessagesTarget.innerHTML = ""
      await this.generateInitial()
    } catch (e) { this.showError("Failed to reset conversation") }
  }

  async loadChat() {
    try {
      const res = await fetch(this.createUrlValue, { headers: this.headers() })
      if (res.ok) {
        const data = await res.json()
        this.renderMessages(data.chat_session.messages)
      }
    } catch (e) { /* no session */ }
  }

  // ---- SSE consumption (mirrors task_chat_controller) -------------------

  async consumeSSE(response, textSpan) {
    const reader = response.body.getReader()
    const decoder = new TextDecoder()
    let buffer = ""
    let fullText = ""
    let error = null
    let thinking = true

    while (true) {
      const { done, value } = await reader.read()
      if (done) break
      buffer += decoder.decode(value, { stream: true })
      const lines = buffer.split("\n")
      buffer = lines.pop()
      for (const line of lines) {
        if (!line.startsWith("data: ")) continue
        let data
        try { data = JSON.parse(line.slice(6)) } catch { continue }
        if (data.done) {
          // final marker
        } else if (data.error) {
          error = data.error
        } else if (typeof data === "string") {
          if (thinking) { this.hideThinking(textSpan); thinking = false }
          fullText += data
          textSpan.innerHTML = this.renderChatMarkdown(fullText) + this.streamingCursor()
        }
      }
      this.scrollChat()
    }
    if (thinking) this.hideThinking(textSpan)
    textSpan.innerHTML = this.renderChatMarkdown(fullText) || this.doneNote()
    this.scrollChat()
    return { fullText, error }
  }

  // ---- chat message DOM -------------------------------------------------

  appendMessage(role, content, author = null) {
    const wrapper = document.createElement("div")
    wrapper.className = role === "user" ? "flex flex-col items-end" : "flex flex-col items-start"
    if (role === "user" && author) {
      const label = document.createElement("div")
      label.textContent = author
      label.style.cssText = "font-size: 0.6875rem; color: var(--color-outline); margin-bottom: 0.125rem; padding-right: 0.5rem;"
      wrapper.appendChild(label)
    }
    const bubble = document.createElement("div")
    bubble.className = role === "user" ? "chat-bubble chat-bubble-user" : "chat-bubble chat-bubble-assistant"
    const textSpan = document.createElement("span")
    textSpan.setAttribute("data-chat-text", "")
    if (role === "assistant" && content) textSpan.innerHTML = this.renderChatMarkdown(content)
    else textSpan.textContent = content
    bubble.appendChild(textSpan)
    wrapper.appendChild(bubble)
    this.chatMessagesTarget.appendChild(wrapper)
    this.scrollChat()
    return wrapper
  }

  renderMessages(messages) {
    this.chatMessagesTarget.innerHTML = ""
    messages.forEach(m => this.appendMessage(m.role, m.content, m.author))
  }

  showThinking(textSpan) {
    textSpan.innerHTML = `<span class="chat-thinking" style="display:inline-flex;gap:0.25rem;align-items:center;padding:0.15rem 0;">
      <span style="width:6px;height:6px;border-radius:50%;background:var(--color-on-surface-variant);animation:chat-thinking-bounce 1.2s infinite ease-in-out;"></span>
      <span style="width:6px;height:6px;border-radius:50%;background:var(--color-on-surface-variant);animation:chat-thinking-bounce 1.2s infinite ease-in-out 0.15s;"></span>
      <span style="width:6px;height:6px;border-radius:50%;background:var(--color-on-surface-variant);animation:chat-thinking-bounce 1.2s infinite ease-in-out 0.3s;"></span>
    </span>`
  }
  hideThinking(textSpan) { const d = textSpan.querySelector(".chat-thinking"); if (d) d.remove() }
  streamingCursor() { return '<span style="display:inline-block;width:6px;height:1em;background:var(--color-on-surface-variant);margin-left:1px;vertical-align:text-bottom;animation:chat-cursor-blink 1s steps(2) infinite;"></span>' }
  doneNote() { return '<span style="color: var(--color-outline); font-size: 0.8125rem;">Breakdown updated — see the left panel.</span>' }

  showError(message) {
    const wrapper = document.createElement("div")
    wrapper.className = "flex justify-center py-4"
    wrapper.innerHTML = `<span class="text-sm" style="color: var(--color-error)">${this.escape(message)}</span>`
    this.chatMessagesTarget.appendChild(wrapper)
    this.scrollChat()
  }

  handleKeydown(event) {
    if (event.key === "Enter" && !event.shiftKey) { event.preventDefault(); this.sendMessage() }
  }

  scrollChat() { if (this.hasChatMessagesTarget) this.chatMessagesTarget.scrollTop = this.chatMessagesTarget.scrollHeight }
  abortIfStreaming() { if (this.abortController) { this.abortController.abort(); this.abortController = null } }

  headers() {
    return {
      "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content,
      "Accept": "application/json"
    }
  }

  escape(s) {
    return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;")
  }

  // Chat markdown: strip <breakdown> JSON (it's rendered on the left), then a
  // minimal markdown pass for the conversational text.
  renderChatMarkdown(text) {
    let src = String(text).replace(/<breakdown>[\s\S]*?<\/breakdown>/g, "").trim()
    src = src.replace(/<breakdown>[\s\S]*$/g, "").trim() // strip an unterminated block mid-stream
    if (!src) return ""
    const escape = (s) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
    src = escape(src)
    const lines = src.split("\n")
    const out = []
    let inUl = false, paraBuf = []
    const flushPara = () => { if (paraBuf.length) { out.push(`<p>${paraBuf.join(" ")}</p>`); paraBuf = [] } }
    const closeUl = () => { if (inUl) { out.push("</ul>"); inUl = false } }
    for (const line of lines) {
      if (/^\s*$/.test(line)) { flushPara(); closeUl(); continue }
      let m
      if ((m = line.match(/^(#{1,6})\s+(.*)$/))) { flushPara(); closeUl(); out.push(`<h${m[1].length}>${this.inline(m[2])}</h${m[1].length}>`); continue }
      if ((m = line.match(/^\s*[-*]\s+(.*)$/))) { flushPara(); if (!inUl) { out.push("<ul>"); inUl = true } out.push(`<li>${this.inline(m[1])}</li>`); continue }
      closeUl(); paraBuf.push(this.inline(line))
    }
    flushPara(); closeUl()
    return out.join("")
  }

  inline(s) {
    return s
      .replace(/`([^`]+)`/g, "<code>$1</code>")
      .replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>")
      .replace(/(^|[^*])\*([^*\s][^*]*?)\*(?!\*)/g, "$1<em>$2</em>")
      .replace(/\[([^\]]+)\]\(([^)\s]+)\)/g, (_m, text, url) =>
        this.safeUrl(url) ? `<a href="${url}" target="_blank" rel="noopener">${text}</a>` : text)
  }

  // Only allow http(s)/mailto/relative URLs in rendered links. Blocks
  // javascript: and data: schemes (chat text is model output derived from
  // untrusted Jira content, so links must not be trusted).
  safeUrl(url) {
    return /^(https?:|mailto:)/i.test(url) || /^[\/#]/.test(url) || !/^[a-z][a-z0-9+.-]*:/i.test(url)
  }
}
