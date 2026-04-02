import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["details", "taskContent", "chatPanel", "chatMessages", "chatInput",
                     "chatHeader", "breadcrumb", "chatBreadcrumb", "expandBtn"]
  static values = {
    state: { type: String, default: "normal" },
    createUrl: String,
    messageUrl: String,
    taskId: Number,
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
    try {
      this.showLoading()
      const response = await fetch(this.createUrlValue, {
        method: "POST",
        headers: this.headers()
      })
      const data = await response.json()
      if (data.error) {
        this.showError(data.error)
        return
      }
      this.hasSessionValue = true
      this.renderMessages(data.chat_session.messages)
    } catch (e) {
      this.showError("Failed to start chat session")
    }
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
    this.appendMessage("user", content)
    const assistantBubble = this.appendMessage("assistant", "")
    const textSpan = assistantBubble.querySelector("[data-chat-text]")
    this.abortController = new AbortController()
    let fullText = ""
    try {
      const response = await fetch(this.messageUrlValue, {
        method: "POST",
        headers: { ...this.headers(), "Content-Type": "application/json" },
        body: JSON.stringify({ content }),
        signal: this.abortController.signal
      })
      const reader = response.body.getReader()
      const decoder = new TextDecoder()
      let buffer = ""
      while (true) {
        const { done, value } = await reader.read()
        if (done) break
        buffer += decoder.decode(value, { stream: true })
        const lines = buffer.split("\n")
        buffer = lines.pop()
        for (const line of lines) {
          if (!line.startsWith("data: ")) continue
          const jsonStr = line.slice(6)
          try {
            const data = JSON.parse(jsonStr)
            if (data.done) {
              // Stream complete — render final markdown
              textSpan.innerHTML = this.renderMarkdown(fullText)
            } else if (data.error) {
              fullText += `\n[Error: ${data.error}]`
              textSpan.textContent = fullText
            } else {
              fullText += data
              textSpan.textContent = fullText
            }
          } catch {
            // Not valid JSON, skip
          }
        }
        this.scrollToBottom()
      }
      // Final render in case no done event was received
      if (fullText) textSpan.innerHTML = this.renderMarkdown(fullText)
    } catch (e) {
      if (e.name !== "AbortError") {
        fullText += "\n[Connection interrupted]"
        textSpan.textContent = fullText
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

  appendMessage(role, content) {
    const wrapper = document.createElement("div")
    wrapper.className = role === "user" ? "flex justify-end" : "flex justify-start"
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
    messages.forEach(msg => this.appendMessage(msg.role, msg.content))
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
    // Escape HTML first to prevent XSS
    const escaped = text
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;")
    // Code blocks
    let html = escaped.replace(/```(\w*)\n([\s\S]*?)```/g, (_m, _lang, code) =>
      `<pre><code>${code.trim()}</code></pre>`)
    // Inline code
    html = html.replace(/`([^`]+)`/g, "<code>$1</code>")
    // Bold
    html = html.replace(/\*\*(.+?)\*\*/g, "<strong>$1</strong>")
    // Italic
    html = html.replace(/\*(.+?)\*/g, "<em>$1</em>")
    // Line breaks
    html = html.replace(/\n/g, "<br>")
    return html
  }

  headers() {
    return {
      "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content,
      "Accept": "application/json"
    }
  }
}
