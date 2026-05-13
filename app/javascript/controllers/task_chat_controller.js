import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["details", "taskContent", "chatPanel", "chatMessages", "chatInput",
                     "chatHeader", "breadcrumb", "chatBreadcrumb", "expandBtn"]
  static values = {
    state: { type: String, default: "normal" },
    createUrl: String,
    messageUrl: String,
    taskId: Number,
    currentUserName: { type: String, default: "" },
    hasSession: { type: Boolean, default: false }
  }

  connect() {
    this.abortController = null
    this.sidebar = document.querySelector("aside.m3-drawer-side")
    this.mainElement = this.element.closest("main")
    this.beforeVisitHandler = () => this.closeChat()
    document.addEventListener("turbo:before-visit", this.beforeVisitHandler)
  }

  disconnect() {
    this.abortIfStreaming()
    if (this.sidebar) this.sidebar.style.display = ""
    document.removeEventListener("turbo:before-visit", this.beforeVisitHandler)
  }

  async openChat() {
    if (this.stateValue !== "normal") return
    this.chatPanelTarget.style.display = "flex"
    this.stateValue = "sideBySide"
    this.applyState()
    if (!this.hasSessionValue) {
      await this.createSession()
    } else {
      await this.loadSession()
    }
  }

  closeChat() {
    this.abortIfStreaming()
    this.stateValue = "normal"
    this.applyState()
  }

  toggleExpand() {
    if (this.stateValue === "sideBySide") {
      this.stateValue = "fullscreen"
    } else if (this.stateValue === "fullscreen") {
      this.stateValue = "sideBySide"
    }
    this.applyState()
  }

  expandChat() { this.toggleExpand() }
  shrinkChat() { this.toggleExpand() }

  applyState() {
    const state = this.stateValue
    if (this.sidebar) {
      this.sidebar.style.display = state === "normal" ? "" : "none"
    }
    if (this.hasDetailsTarget) {
      this.detailsTarget.style.display = state === "normal" ? "" : "none"
    }
    if (this.hasTaskContentTarget) {
      this.taskContentTarget.style.display = state === "fullscreen" ? "none" : ""
    }
    if (this.hasChatPanelTarget) {
      if (state === "normal") {
        this.chatPanelTarget.style.display = "none"
      } else if (state === "fullscreen") {
        this.chatPanelTarget.style.display = "flex"
        this.chatPanelTarget.style.width = "100%"
        this.chatPanelTarget.style.maxWidth = "720px"
        this.chatPanelTarget.style.margin = "0 auto"
        this.chatPanelTarget.style.borderLeft = "none"
        this.chatPanelTarget.style.position = "static"
        this.chatPanelTarget.style.height = this.computeChatHeight()
        this.chatPanelTarget.style.alignSelf = ""
      } else {
        this.chatPanelTarget.style.display = "flex"
        this.chatPanelTarget.style.width = "45%"
        this.chatPanelTarget.style.maxWidth = ""
        this.chatPanelTarget.style.margin = ""
        this.chatPanelTarget.style.borderLeft = ""
        this.chatPanelTarget.style.position = "sticky"
        this.chatPanelTarget.style.top = "0"
        this.chatPanelTarget.style.height = this.computeChatHeight()
        this.chatPanelTarget.style.alignSelf = "flex-start"
      }
    }
    if (this.hasBreadcrumbTarget) {
      this.breadcrumbTarget.style.display = state === "normal" ? "" : "none"
    }
    if (this.hasChatBreadcrumbTarget) {
      this.chatBreadcrumbTarget.style.display = state === "normal" ? "none" : ""
    }
    if (this.hasChatHeaderTarget) {
      this.chatHeaderTarget.style.display = state === "fullscreen" ? "" : "none"
    }
    if (this.hasExpandBtnTarget) {
      const isFullscreen = state === "fullscreen"
      this.expandBtnTarget.innerHTML = isFullscreen
        ? '<svg xmlns="http://www.w3.org/2000/svg" class="h-4 w-4" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2"><path stroke-linecap="round" stroke-linejoin="round" d="M9 9V4.5M9 9H4.5M9 9L3.75 3.75M9 15v4.5M9 15H4.5M9 15l-5.25 5.25M15 9h4.5M15 9V4.5M15 9l5.25-5.25M15 15h4.5M15 15v4.5m0-4.5l5.25 5.25" /></svg> Shrink'
        : '<svg xmlns="http://www.w3.org/2000/svg" class="h-4 w-4" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2"><path stroke-linecap="round" stroke-linejoin="round" d="M3.75 3.75v4.5m0-4.5h4.5m-4.5 0L9 9M3.75 20.25v-4.5m0 4.5h4.5m-4.5 0L9 15M20.25 3.75h-4.5m4.5 0v4.5m0-4.5L15 9m5.25 11.25h-4.5m4.5 0v-4.5m0 4.5L15 15" /></svg> Expand'
    }
    if (state !== "normal" && this.hasChatMessagesTarget) {
      this.scrollToBottom()
    }
  }

  async createSession() {
    this.chatMessagesTarget.innerHTML = ""
    const assistantBubble = this.appendMessage("assistant", "")
    const textSpan = assistantBubble.querySelector("[data-chat-text]")
    this.showThinking(textSpan)

    try {
      const response = await fetch(this.createUrlValue, {
        method: "POST",
        headers: this.headers()
      })
      const result = await this.consumeSSE(response, textSpan)
      if (result.error) {
        this.showError(result.error)
        return
      }
      this.hasSessionValue = true
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
          textSpan.innerHTML = this.renderMarkdown(fullText) + this.streamingCursor()
        }
      }
      this.scrollToBottom()
    }

    if (thinking) this.hideThinking(textSpan)
    if (fullText) textSpan.innerHTML = this.renderMarkdown(fullText)
    return { fullText, error }
  }

  showThinking(textSpan) {
    textSpan.innerHTML = `
      <span class="chat-thinking" aria-label="Claude is thinking" style="display: inline-flex; gap: 0.25rem; align-items: center; padding: 0.15rem 0;">
        <span style="width: 6px; height: 6px; border-radius: 50%; background: var(--color-on-surface-variant); animation: chat-thinking-bounce 1.2s infinite ease-in-out;"></span>
        <span style="width: 6px; height: 6px; border-radius: 50%; background: var(--color-on-surface-variant); animation: chat-thinking-bounce 1.2s infinite ease-in-out 0.15s;"></span>
        <span style="width: 6px; height: 6px; border-radius: 50%; background: var(--color-on-surface-variant); animation: chat-thinking-bounce 1.2s infinite ease-in-out 0.3s;"></span>
      </span>
    `
  }

  hideThinking(textSpan) {
    const dots = textSpan.querySelector(".chat-thinking")
    if (dots) dots.remove()
  }

  streamingCursor() {
    return '<span class="chat-cursor" style="display: inline-block; width: 6px; height: 1em; background: var(--color-on-surface-variant); margin-left: 1px; vertical-align: text-bottom; animation: chat-cursor-blink 1s steps(2) infinite;"></span>'
  }

  async loadSession() {
    try {
      const response = await fetch(this.createUrlValue, { headers: this.headers() })
      if (response.ok) {
        const data = await response.json()
        this.renderMessages(data.chat_session.messages)
      }
    } catch (e) {
      // Ignore — session may not exist yet
    }
  }

  async sendMessage(event) {
    event?.preventDefault()
    const input = this.chatInputTarget
    const content = input.value.trim()
    if (!content) return
    input.value = ""
    input.disabled = true
    this.appendMessage("user", content, this.currentUserNameValue || null)
    const assistantBubble = this.appendMessage("assistant", "")
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
      await this.consumeSSE(response, textSpan)
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
    if (role === "assistant" && content) {
      textSpan.innerHTML = this.renderMarkdown(content)
    } else {
      textSpan.textContent = content
    }
    bubble.appendChild(textSpan)
    wrapper.appendChild(bubble)
    this.chatMessagesTarget.appendChild(wrapper)
    this.scrollToBottom()
    return wrapper
  }

  renderMessages(messages) {
    this.chatMessagesTarget.innerHTML = ""
    messages.forEach(msg => this.appendMessage(msg.role, msg.content, msg.author))
  }

  async resetConversation() {
    if (!confirm("Reset this conversation? The current chat will be hidden and a new conversation will start.\n\nDrafts created so far will remain available.")) return

    this.abortIfStreaming()
    try {
      const response = await fetch(this.createUrlValue, {
        method: "DELETE",
        headers: this.headers()
      })
      if (!response.ok && response.status !== 204) {
        this.showError("Failed to reset conversation")
        return
      }
      this.hasSessionValue = false
      this.chatMessagesTarget.innerHTML = ""
      await this.createSession()
    } catch (e) {
      this.showError("Failed to reset conversation")
    }
  }

  showLoading() {
    this.chatMessagesTarget.innerHTML = '<div class="flex justify-center py-8"><span class="text-sm" style="color: var(--color-outline)">Starting chat session...</span></div>'
  }

  showError(message) {
    this.chatMessagesTarget.innerHTML = `<div class="flex justify-center py-8"><span class="text-sm" style="color: var(--color-error)">${message}</span></div>`
  }

  computeChatHeight() {
    if (!this.mainElement) return "calc(100vh - 6rem)"
    // Use the main element's visible height minus the space above the flex container
    const mainRect = this.mainElement.getBoundingClientRect()
    const flexContainer = this.chatPanelTarget.parentElement
    const flexRect = flexContainer.getBoundingClientRect()
    const available = mainRect.bottom - flexRect.top
    return `${Math.max(available, 300)}px`
  }

  scrollToBottom() {
    if (this.hasChatMessagesTarget) {
      this.chatMessagesTarget.scrollTop = this.chatMessagesTarget.scrollHeight
    }
  }

  abortIfStreaming() {
    if (this.abortController) {
      this.abortController.abort()
      this.abortController = null
    }
  }

  renderMarkdown(text) {
    const escape = (s) => s
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;")

    // Pull out <draft>…</draft> blocks first. The inner content is rendered
    // recursively and wrapped in a styled card so it stands out as the AI's
    // refined ticket description.
    const draftBlocks = []
    let preDraft = text.replace(/<draft>\s*([\s\S]*?)\s*<\/draft>/g, (_m, body) => {
      draftBlocks.push(body)
      return `\nDRAFTBLOCK${draftBlocks.length - 1}\n`
    })

    // Extract fenced code blocks first so their content isn't transformed
    const codeBlocks = []
    let src = preDraft.replace(/```(\w*)\n([\s\S]*?)```/g, (_m, _lang, code) => {
      codeBlocks.push(`<pre><code>${escape(code.replace(/\n$/, ""))}</code></pre>`)
      return ` CODEBLOCK${codeBlocks.length - 1} `
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
    html = html.replace(/ CODEBLOCK(\d+) /g, (_m, i) => codeBlocks[parseInt(i, 10)])
    // Restore draft blocks: render each inner body as markdown, wrap in card.
    html = html.replace(/<p>\s*DRAFTBLOCK(\d+)\s*<\/p>|DRAFTBLOCK(\d+)/g, (_m, a, b) => {
      const idx = parseInt(a ?? b, 10)
      const body = draftBlocks[idx]
      const inner = this.renderMarkdown(body)
      return `<div class="chat-draft"><div class="chat-draft__label">AI refined ticket description</div>${inner}</div>`
    })
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
    // Links [text](url)
    h = h.replace(/\[([^\]]+)\]\(([^)\s]+)\)/g,
      '<a href="$2" target="_blank" rel="noopener">$1</a>')
    return h
  }

  headers() {
    return {
      "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content,
      "Accept": "application/json"
    }
  }
}
