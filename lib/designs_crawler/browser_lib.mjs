// The setup browser's rules, apart from the browser (browser.mjs uses them):
// what counts as the test environment, what signs out of it, and what
// fill_form types into a field.

export const NOT_ALLOWED = "Not allowed: that leaves the test environment."
export const SIGNS_OUT = "Not allowed: that signs out of the test environment."

const SIGN_OUT = /log\s*[-_]?\s*out|sign\s*[-_]?\s*out|logout|signout|wyloguj/i

// Whether url, read against the test environment's address, stays on its
// origin. A javascript: or data: address has none, so it does not.
export function sameOrigin(base, url) {
  try {
    return new URL(url, base).origin === new URL(base).origin
  } catch {
    return false
  }
}

// Whether a control, by its text or the address it goes to, signs out.
export function signOut(text, href) {
  return SIGN_OUT.test(String(text || "")) || SIGN_OUT.test(String(href || ""))
}

// An e-mail address moved to example.test, which never takes mail: what the
// model asks fill_form to type into an e-mail field goes there too.
export function testDomain(value) {
  const text = String(value)
  return /^[^@\s]+@[^@\s]+$/.test(text) ? text.replace(/@.*$/, "@example.test") : text
}

// Whether a field is for an e-mail address, by its type, name or label.
export function emailField(field) {
  return String(field.type || "").toLowerCase() === "email" || /e-?mail/i.test(`${field.name || ""} ${field.label || ""}`)
}

// What fill_form types into a field, or null to leave it as it is. A field is
// { type, name, label, required, min, max, minLength, maxLength, pattern,
// options }. Valid values are plausible test data: every e-mail address is on
// example.test, which never takes mail. Invalid ones break the field's rule.
// A password field is never filled, either way: it could lock a test account
// out of every feature after.
export function valueFor(field, mode = "valid") {
  const type = String(field.type || "text").toLowerCase()
  if (type === "password" || type === "file") return null
  return mode === "invalid" ? invalid(field, type) : valid(field, type)
}

function valid(field, type) {
  const words = `${field.name || ""} ${field.label || ""}`.toLowerCase()
  switch (type) {
    case "email": return testAddress()
    case "tel": return "+48 600 100 200"
    case "url": return "https://example.test"
    case "number":
    case "range": return String(number(field))
    case "date": return date(field)
    case "datetime-local": return `${date(field)}T10:00`
    case "time": return "10:00"
    case "month": return date(field).slice(0, 7)
    case "week": return week()
    case "color": return "#4f46e5"
    case "checkbox": return field.required ? true : null
    case "radio": return null
    case "select": return (field.options || []).find((option) => option.value !== "")?.value ?? null
    case "textarea": return fit("Notes for the test: Flosis is checking this form.", field)
  }
  if (/e-?mail/.test(words)) return testAddress()
  if (/phone|tel(?:ephone)?\b|mobile|telefon/.test(words)) return "+48 600 100 200"
  if (/url|website|link/.test(words)) return "https://example.test"
  if (/first.?name|given|imi[eę]/.test(words)) return fit("Anna", field)
  if (/last.?name|surname|family|nazwisko/.test(words)) return fit("Kowalska", field)
  if (/city|town|miasto/.test(words)) return fit("Kraków", field)
  if (/zip|postal|post.?code|kod/.test(words)) return fit("30-001", field)
  if (/street|address|adres/.test(words)) return fit("ul. Floriańska 12", field)
  if (/company|organi[sz]ation|firma/.test(words)) return fit("Acme Test", field)
  if (/amount|price|rate|cost|hours|quantity|qty|kwota|cena/.test(words)) return "100"
  return fit(`Test ${(field.label || field.name || "value").replace(/[\[\]_]+/g, " ").trim().toLowerCase()}`.slice(0, 60), field)
}

function invalid(field, type) {
  switch (type) {
    case "email": return "not-an-email"
    case "number":
    case "range":
      if (field.min !== null && field.min !== undefined && field.min !== "") return String(Number(field.min) - 1)
      if (field.max !== null && field.max !== undefined && field.max !== "") return String(Number(field.max) + 1)
      return field.required ? "" : null
    case "checkbox": return field.required ? false : null
    case "radio":
    case "select": return field.required ? "" : null
  }
  if (field.required) return ""
  if (field.maxLength) return "x".repeat(Number(field.maxLength) + 1)
  if (field.pattern) return "!!!"
  return null
}

// A text that fits the field's length limits.
function fit(text, field) {
  let value = text
  if (field.maxLength) value = value.slice(0, Number(field.maxLength))
  if (field.minLength && value.length < Number(field.minLength)) value = value.padEnd(Number(field.minLength), "x")
  return value
}

function number(field) {
  const min = field.min === null || field.min === undefined || field.min === "" ? null : Number(field.min)
  const max = field.max === null || field.max === undefined || field.max === "" ? null : Number(field.max)
  if (min !== null) return min
  if (max !== null) return Math.min(1, max)
  return 1
}

// A week from today, or the field's earliest day when that is later.
function date(field) {
  const day = new Date(Date.now() + 7 * 24 * 3600 * 1000).toISOString().slice(0, 10)
  return field.min && String(field.min) > day ? String(field.min).slice(0, 10) : day
}

function week() {
  const now = new Date()
  const start = new Date(Date.UTC(now.getUTCFullYear(), 0, 1))
  const n = Math.ceil(((now - start) / 86400000 + start.getUTCDay() + 1) / 7)
  return `${now.getUTCFullYear()}-W${String(n).padStart(2, "0")}`
}

// A new address each time, so that a form that wants a unique e-mail takes it.
function testAddress() {
  return `flosis.${Date.now().toString(36)}${Math.random().toString(36).slice(2, 5)}@example.test`
}
