// The setup browser's rules, without a browser: what counts as the test
// environment, what signs out of it, and what fill_form types into a field.
import { test } from "node:test"
import assert from "node:assert/strict"
import { sameOrigin, signOut, testDomain, valueFor } from "../browser_lib.mjs"

test("only the test environment's origin is the test environment", () => {
  assert.equal(sameOrigin("https://a.test/x", "https://a.test/y?z=1"), true)
  assert.equal(sameOrigin("https://a.test", "/relative/path"), true)
  assert.equal(sameOrigin("https://a.test", "https://b.test/"), false)
  assert.equal(sameOrigin("https://a.test", "//b.test/x"), false)
  assert.equal(sameOrigin("https://a.test", "http://a.test/"), false)
  assert.equal(sameOrigin("https://a.test", "javascript:alert(1)"), false)
  assert.equal(sameOrigin("https://a.test", "not a url at all ::"), true, "a relative oddity stays on the origin")
})

test("sign-out controls are recognised by their text or their address", () => {
  for (const [text, href] of [ [ "Log out", "" ], [ "Sign out", "/session" ], [ "", "/users/sign_out" ], [ "Logout", "" ], [ "Wyloguj", "" ], [ "", "/logout?next=/" ] ]) {
    assert.equal(signOut(text, href), true, `${text} ${href}`)
  }
  assert.equal(signOut("Delete project", "/projects/1"), false)
  assert.equal(signOut("Logbook", "/logs"), false)
})

test("valid values follow the field", () => {
  assert.match(valueFor({ type: "email", label: "E-mail" }, "valid"), /@example\.test$/)
  assert.match(valueFor({ type: "text", name: "user[email]" }, "valid"), /@example\.test$/, "an e-mail in a text field is a test address too")
  assert.equal(valueFor({ type: "number", min: "3", max: "9" }, "valid"), "3")
  assert.equal(valueFor({ type: "number" }, "valid"), "1")
  assert.equal(valueFor({ type: "select", options: [ { value: "", text: "Pick one" }, { value: "pl", text: "Polish" } ] }, "valid"), "pl")
  assert.equal(valueFor({ type: "select", options: [ { value: "", text: "Pick one" } ] }, "valid"), null)
  assert.match(valueFor({ type: "date" }, "valid"), /^\d{4}-\d{2}-\d{2}$/)
  assert.match(valueFor({ type: "datetime-local" }, "valid"), /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}$/)
  assert.equal(valueFor({ type: "checkbox", required: true }, "valid"), true)
  assert.equal(valueFor({ type: "checkbox", required: false }, "valid"), null)
  assert.ok(valueFor({ type: "text", label: "Title", maxLength: 5 }, "valid").length <= 5)
  assert.ok(valueFor({ type: "textarea", label: "Notes" }, "valid").length > 10)
  assert.equal(valueFor({ type: "file" }, "valid"), null)
})

test("invalid values break the field", () => {
  assert.equal(valueFor({ type: "text", label: "Title", required: true }, "invalid"), "")
  assert.doesNotMatch(valueFor({ type: "email", label: "E-mail" }, "invalid"), /@/)
  assert.equal(valueFor({ type: "number", min: "3" }, "invalid"), "2")
  assert.equal(valueFor({ type: "number", max: "9" }, "invalid"), "10")
  assert.equal(valueFor({ type: "checkbox", required: true }, "invalid"), false)
})

test("an address the model gives is moved to example.test", () => {
  assert.equal(testDomain("jan@acme.com"), "jan@example.test")
  assert.equal(testDomain("anna@example.test"), "anna@example.test")
  assert.equal(testDomain("not an address"), "not an address")
})

test("a password is never filled", () => {
  assert.equal(valueFor({ type: "password" }, "valid"), null)
  assert.equal(valueFor({ type: "password", required: true }, "invalid"), null)
})
