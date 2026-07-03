import { Controller } from "@hotwired/stimulus"

// Clar-skinned port of task_chat_controller.js's SSE core (create/resume/
// message/reset streaming against ChatStreaming-backed endpoints), re-skinned
// to clar-bubble-ai/clar-bubble-user bubbles. Unlike task_chat_controller.js
// this has NO panel-state machine (side-by-side/fullscreen/normal) — the
// Briefing workspace grid (Task 4.1) owns layout, this controller only ever
// renders inside its fixed panel.
//
// Used for the Briefing stage's brief chat today (persona: "briefing"); the
// Details stage chat (Task 5.1) is expected to reuse this same controller
// with persona: "details" and its own create/show/message/reset URLs.
export default class extends Controller {
  static targets = ["messages", "input"]
  static values = {
    createUrl: String,
    showUrl: String,
    messageUrl: String,
    resetUrl: String,
    persona: String,
    currentUserName: { type: String, default: "" },
    hasSession: { type: Boolean, default: false }
  }

  connect() {
    this.abortController = null
    this.boundResetConversation = this.resetConversation.bind(this)
    window.addEventListener("clar:reset-conversation", this.boundResetConversation)
    this.loadOrStart()
  }

  disconnect() {
    this.abortIfStreaming()
    window.removeEventListener("clar:reset-conversation", this.boundResetConversation)
  }

  async loadOrStart() {
    try {
      const response = await fetch(this.showUrlValue || this.createUrlValue, { headers: this.headers() })
      if (response.ok) {
        const data = await response.json()
        this.hasSessionValue = true
        this.renderMessages(data.chat_session.messages)
        return
      }
    } catch (e) {
      // fall through to starting a fresh session
    }
    await this.createSession()
  }

  async createSession(mode = null) {
    this.messagesTarget.innerHTML = ""
    const assistantBubble = this.appendMessage("ai", "")
    const textSpan = assistantBubble.querySelector("[data-chat-text]")
    this.showThinking(textSpan)

    const url = mode ? `${this.createUrlValue}?mode=${encodeURIComponent(mode)}` : this.createUrlValue

    try {
      const response = await fetch(url, {
        method: "POST",
        headers: this.headers()
      })
      const result = await this.consumeSSE(response, textSpan)
      if (result.error) {
        this.showError(result.error)
        return
      }
      this.hasSessionValue = true
      this.dispatchDocumentUpdated()
    } catch (e) {
      this.showError("Failed to start chat session")
    }
  }

  // Reads an SSE response body, streaming text into `textSpan` as it arrives.
  // Returns { fullText, error } when the stream completes.
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
        const jsonStr = line.slice(6)
        let data
        try { data = JSON.parse(jsonStr) } catch { continue }
        if (data.done) {
          // final marker — nothing else to do, we'll re-render below
        } else if (data.error) {
          error = data.error
        } else if (typeof data === "string") {
          if (thinking) { this.hideThinking(textSpan); thinking = false }
          fullText += data
          textSpan.innerHTML = this.renderMarkdown(this.stripResultBlocks(fullText)) + this.streamingCursor()
        }
      }
      this.scrollToBottom()
    }

    if (thinking) this.hideThinking(textSpan)
    if (fullText) textSpan.innerHTML = this.renderMarkdown(this.stripResultBlocks(fullText))
    return { fullText, error }
  }

  showThinking(textSpan) {
    textSpan.innerHTML = `
      <span class="chat-thinking" aria-label="Clar is thinking" style="display: inline-flex; gap: 5px; align-items: center; padding: 2px 0;">
        <span class="clar-blink"></span>
        <span class="clar-blink" style="animation-delay: .2s"></span>
        <span class="clar-blink" style="animation-delay: .4s"></span>
      </span>
    `
  }

  hideThinking(textSpan) {
    const dots = textSpan.querySelector(".chat-thinking")
    if (dots) dots.remove()
  }

  streamingCursor() {
    return '<span class="chat-cursor" style="display: inline-block; width: 6px; height: 1em; background: var(--faint); margin-left: 1px; vertical-align: text-bottom; animation: chat-cursor-blink 1s steps(2) infinite;"></span>'
  }

  async sendMessage(event) {
    event?.preventDefault()
    const input = this.inputTarget
    const content = input.value.trim()
    if (!content) return
    input.value = ""
    input.disabled = true
    this.appendMessage("user", content, this.currentUserNameValue || null)
    const assistantBubble = this.appendMessage("ai", "")
    const textSpan = assistantBubble.querySelector("[data-chat-text]")
    this.showThinking(textSpan)
    this.abortController = new AbortController()
    try {
      const response = await fetch(this.messageUrlValue, {
        method: "POST",
        headers: { ...this.headers(), "Content-Type": "application/json" },
        body: JSON.stringify({ content }),
        signal: this.abortController.signal
      })
      const result = await this.consumeSSE(response, textSpan)
      if (result.error) {
        this.showError(result.error)
      } else {
        this.dispatchDocumentUpdated()
      }
    } catch (e) {
      if (e.name !== "AbortError") {
        this.hideThinking(textSpan)
        textSpan.textContent = (textSpan.textContent || "") + "\n[Connection interrupted]"
      }
    } finally {
      input.disabled = false
      input.focus()
      this.abortController = null
      this.scrollToBottom()
    }
  }

  handleKeydown(event) {
    if (event.key === "Enter" && !event.shiftKey) {
      event.preventDefault()
      this.sendMessage()
    }
  }

  appendMessage(role, content, author = null) {
    const wrapper = document.createElement("div")
    wrapper.style.cssText = "display:flex;gap:10px;align-items:flex-start;" +
      (role === "ai" ? "" : "flex-direction:row-reverse")

    if (role === "ai") {
      const avatar = document.createElement("div")
      avatar.className = "clar-bubble-avatar"
      avatar.textContent = "AI"
      wrapper.appendChild(avatar)
    }

    const bubble = document.createElement("div")
    bubble.className = role === "ai" ? "clar-bubble-ai clar-prose" : "clar-bubble-user"
    const textSpan = document.createElement("span")
    textSpan.setAttribute("data-chat-text", "")
    if (role === "ai" && content) {
      textSpan.innerHTML = this.renderMarkdown(this.stripResultBlocks(content))
    } else {
      textSpan.textContent = content
    }
    bubble.appendChild(textSpan)

    if (role === "user" && author) {
      const label = document.createElement("div")
      label.textContent = author
      label.style.cssText = "font-size:11px;color:var(--faint);margin-bottom:2px;text-align:right;"
      wrapper.appendChild(bubble)
      wrapper.insertBefore(label, bubble)
    } else {
      wrapper.appendChild(bubble)
    }

    this.messagesTarget.appendChild(wrapper)
    this.scrollToBottom()
    return wrapper
  }

  renderMessages(messages) {
    this.messagesTarget.innerHTML = ""
    messages.forEach(msg => this.appendMessage(msg.role === "assistant" ? "ai" : msg.role, msg.content, msg.author))
  }

  // Tier 1 — "Reset session" (persona-banner button, behind the "Reset AI
  // session" confirmation modal, _reset_modal.html.erb). Full restart: no
  // mode param, so build_initial_prompt behaves exactly as it does for a
  // brand-new session. All saved brief versions and the description are
  // untouched (destroy only soft-closes the ChatSession; briefs belong to
  // the task, not the session).
  async resetSession() {
    await this.performReset(null, "Chat reset · all versions kept")
  }

  // Tier 2 — "Reset chat" (document-panel footer, no modal; dispatched here
  // via the clar:reset-conversation window event from
  // clar_reset_chat_controller.js). Passes mode=refine_current so
  // build_initial_prompt nudges the AI to revise the current brief instead
  // of starting from zero.
  async resetConversation() {
    await this.performReset("refine_current", "Conversation reset — current version kept")
  }

  async performReset(mode, toastMessage) {
    this.abortIfStreaming()
    try {
      const response = await fetch(this.resetUrlValue || this.createUrlValue, {
        method: "DELETE",
        headers: this.headers()
      })
      if (!response.ok && response.status !== 204) {
        this.showError("Failed to reset conversation")
        return
      }
      this.hasSessionValue = false
      this.messagesTarget.innerHTML = ""
      await this.createSession(mode)
      window.dispatchEvent(new CustomEvent("clar:toast", { detail: { message: toastMessage } }))
    } catch (e) {
      this.showError("Failed to reset conversation")
    }
  }

  showError(message) {
    this.messagesTarget.innerHTML = `<div style="display:flex;justify-content:center;padding:2rem"><span style="font-size:13px;color:var(--danger)">${message}</span></div>`
  }

  scrollToBottom() {
    if (this.hasMessagesTarget) {
      this.messagesTarget.scrollTop = this.messagesTarget.scrollHeight
    }
  }

  abortIfStreaming() {
    if (this.abortController) {
      this.abortController.abort()
      this.abortController = null
    }
  }

  // The right-hand document panel (Task 4.3) listens for this to refresh
  // (e.g. reload a Turbo frame) whenever a completed AI turn may have
  // produced a new <brief>/<draft> block. Harmless to dispatch before that
  // panel exists.
  dispatchDocumentUpdated() {
    window.dispatchEvent(new CustomEvent("clar:document-updated", { detail: { persona: this.personaValue } }))
  }

  // <brief>/<draft> blocks are the AI's structured output for the document
  // panel — they should never show up inline in the chat bubbles themselves.
  stripResultBlocks(text) {
    return text.replace(/<brief>[\s\S]*?<\/brief>/g, "").replace(/<draft>[\s\S]*?<\/draft>/g, "").trim()
  }

  renderMarkdown(text) {
    const escape = (s) => s
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;")

    // Extract fenced code blocks first so their content isn't transformed
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
      if (paraBuf.length) {
        out.push(`<p>${paraBuf.join(" ")}</p>`)
        paraBuf = []
      }
    }
    const closeLists = () => {
      if (inUl) { out.push("</ul>"); inUl = false }
      if (inOl) { out.push("</ol>"); inOl = false }
    }

    for (const rawLine of lines) {
      const line = rawLine
      if (/^\s*$/.test(line)) { flushPara(); closeLists(); continue }

      let m
      if ((m = line.match(/^(#{1,6})\s+(.*)$/))) {
        flushPara(); closeLists()
        const level = m[1].length
        out.push(`<h${level}>${this.inlineMd(m[2])}</h${level}>`)
        continue
      }
      if ((m = line.match(/^\s*[-*]\s+(.*)$/))) {
        flushPara()
        if (inOl) { out.push("</ol>"); inOl = false }
        if (!inUl) { out.push("<ul>"); inUl = true }
        out.push(`<li>${this.inlineMd(m[1])}</li>`)
        continue
      }
      if ((m = line.match(/^\s*\d+\.\s+(.*)$/))) {
        flushPara()
        if (inUl) { out.push("</ul>"); inUl = false }
        if (!inOl) { out.push("<ol>"); inOl = true }
        out.push(`<li>${this.inlineMd(m[1])}</li>`)
        continue
      }
      closeLists()
      paraBuf.push(this.inlineMd(line))
    }
    flushPara(); closeLists()

    let html = out.join("")
    // Restore code blocks
    html = html.replace(/ CODEBLOCK(\d+) /g, (_m, i) => codeBlocks[parseInt(i, 10)])
    return html
  }

  inlineMd(s) {
    // Already HTML-escaped; just apply inline markdown
    let h = s
    // Inline code
    h = h.replace(/`([^`]+)`/g, "<code>$1</code>")
    // Bold
    h = h.replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>")
    // Italic (single * not adjacent to space)
    h = h.replace(/(^|[^*])\*([^*\s][^*]*?)\*(?!\*)/g, "$1<em>$2</em>")
    // Links [text](url) — only safe schemes (block javascript:/data:)
    h = h.replace(/\[([^\]]+)\]\(([^)\s]+)\)/g, (_m, text, url) =>
      this.safeUrl(url) ? `<a href="${url}" target="_blank" rel="noopener">${text}</a>` : text)
    return h
  }

  // Only allow http(s)/mailto/relative URLs in rendered links. Chat text is
  // model output derived from untrusted Jira content, so links must not be trusted.
  safeUrl(url) {
    return /^(https?:|mailto:)/i.test(url) || /^[\/#]/.test(url) || !/^[a-z][a-z0-9+.-]*:/i.test(url)
  }

  headers() {
    return {
      "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content,
      "Accept": "application/json"
    }
  }
}
