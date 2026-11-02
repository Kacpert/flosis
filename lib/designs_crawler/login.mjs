// Signing in to a test environment as one context (sign_in.mjs uses it): the
// first e-mail or text field takes the username, the first password field
// the password, and the form is submitted. Signed in means the browser left
// the login page and shows no password field.
export async function logIn(page, role) {
  const login = new URL(role.loginUrl)
  await page.goto(login.href, { waitUntil: "load" })
  const user = page.locator("input[type=email], input[name*=email i], input[type=text]").first()
  const password = page.locator("input[type=password]").first()
  await user.fill(role.username)
  await password.fill(role.password)
  await Promise.all([
    page.waitForURL((url) => url.pathname !== login.pathname, { timeout: 15_000 }).catch(() => {}),
    password.evaluate((field) => (field.form ? field.form.requestSubmit() : null)),
  ])
  await page.waitForLoadState("load")
  const stillHere = new URL(page.url()).pathname === login.pathname
  const passwordShown = await page.locator("input[type=password]").first().isVisible().catch(() => false)
  if (stillHere || passwordShown) throw new Error("login failed (still on the login page)")
}

// An error's first line with every secret masked: Playwright repeats what it
// was asked to type in some of its errors.
export function safe(error, secrets) {
  const message = String((error && error.message) || error).split("\n")[0]
  return secrets.reduce((out, secret) => out.split(secret).join("••••••"), message)
}
