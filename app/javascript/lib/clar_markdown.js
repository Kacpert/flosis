// Shared conservative regex Markdown -> HTML renderer, ported verbatim from
// task_chat_controller.js's renderMarkdown/inlineMd/safeUrl (minus the
// <draft>…</draft> block handling, which is chat-specific). XSS-safe: the
// source is HTML-escaped before any tag is introduced, and links only allow
// http(s)/mailto/relative URLs.
//
// Used by clar_chat_controller.js (Task 4.2, inline copy — not yet
// refactored to import this) and clar_markdown_controller.js (Task 4.3, the
// document panel's static content renderer).
export function renderMarkdown(text) {
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
      out.push(`<h${level}>${inlineMd(m[2])}</h${level}>`)
      continue
    }
    if ((m = line.match(/^\s*[-*]\s+(.*)$/))) {
      flushPara()
      if (inOl) { out.push("</ol>"); inOl = false }
      if (!inUl) { out.push("<ul>"); inUl = true }
      out.push(`<li>${inlineMd(m[1])}</li>`)
      continue
    }
    if ((m = line.match(/^\s*\d+\.\s+(.*)$/))) {
      flushPara()
      if (inUl) { out.push("</ul>"); inUl = false }
      if (!inOl) { out.push("<ol>"); inOl = true }
      out.push(`<li>${inlineMd(m[1])}</li>`)
      continue
    }
    closeLists()
    paraBuf.push(inlineMd(line))
  }
  flushPara(); closeLists()

  let html = out.join("")
  // Restore code blocks
  html = html.replace(/ CODEBLOCK(\d+) /g, (_m, i) => codeBlocks[parseInt(i, 10)])
  return html
}

function inlineMd(s) {
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
    safeUrl(url) ? `<a href="${url}" target="_blank" rel="noopener">${text}</a>` : text)
  return h
}

// Only allow http(s)/mailto/relative URLs in rendered links. Content here is
// derived from Jira/AI text, so links must not be trusted.
function safeUrl(url) {
  return /^(https?:|mailto:)/i.test(url) || /^[\/#]/.test(url) || !/^[a-z][a-z0-9+.-]*:/i.test(url)
}
