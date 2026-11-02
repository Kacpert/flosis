import { Controller } from "@hotwired/stimulus"

// Tiny bridge for the document panel's "Reset chat" button (Task 4.3/4.4).
// The document panel lives in a separate turbo-frame from the chat panel, so
// there's no shared Stimulus controller scope to call clar-chat#resetConversation
// directly — instead this dispatches a window CustomEvent (same cross-panel
// convention as clar:document-updated / clar:toast elsewhere), which
// clar_chat_controller.js listens for.
export default class extends Controller {
  dispatch() {
    window.dispatchEvent(new CustomEvent("clar:reset-conversation"))
  }
}
