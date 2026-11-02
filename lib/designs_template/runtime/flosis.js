// The design repo's runtime: no build step, no dependencies. Every page loads
// it by a path relative to the page:
//
//   <script src="runtime/flosis.js"></script>      a page at the repo root
//   <script src="../runtime/flosis.js"></script>   a page one folder down
//
// In this order, it
//   1. finds the repo root, the folder above runtime/: every file below and
//      every <x-include src> is read from there;
//   2. reads the base kit from runtime/config.json;
//   3. adds design-system/theme.css to the page;
//   4. replaces each <x-include src> with the component it names, whose own
//      paths are relative to the repo root, as src is;
//   5. applies the contexts that ?ctx= names (designs/contexts.json);
//   6. makes same-origin links carry ?ctx= on to the next page;
//   7. loads the kit's runtime/kit.js last, so that it sees the finished page;
// then dispatches "flosis:ready" on document and resolves window.Flosis.ready.
//
// Nothing fails silently: what cannot be loaded shows on the page as a red box.
(() => {
  "use strict";

  // Components may include components; still more of them after ten rounds is a cycle.
  const MAX_ROUNDS = 10;
  // The base kits the template has, which runtime/config.json names.
  const KITS = ["tailwind4", "plain"];
  const PLACEHOLDER = /\{\{\s*([\w-]+)\s*\}\}/g;
  const ESCAPES = { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" };

  // 1. Read now: currentScript is only set while this script first runs.
  const root = new URL("..", document.currentScript.src).href;

  const domReady = new Promise((resolve) => {
    if (document.readyState === "loading") {
      document.addEventListener("DOMContentLoaded", resolve, { once: true });
    } else {
      resolve();
    }
  });

  const Flosis = (window.Flosis = { root, ctx: {} });
  Flosis.ready = run().then(() => {
    document.dispatchEvent(new Event("flosis:ready"));
  });

  async function run() {
    try {
      if (location.protocol === "file:") {
        showError("These pages load their parts over HTTP: serve the repo (python3 -m http.server 8000) and open http://localhost:8000.");
        return;
      }
      const kit = await readKit();
      if (kit) await addTheme(kit);
      await domReady;
      await resolveIncludes();
      await applyContexts();
      carryContexts();
      if (kit === "tailwind4") await loadKit();
    } catch (error) {
      showError(`The Flosis runtime stopped: ${error.message}`);
    }
  }

  // 2. A kit missing or unknown is reported too: the page would only look
  // unstyled, with nothing to say why.
  async function readKit() {
    let kit;
    try {
      kit = JSON.parse(await read("runtime/config.json")).kit;
    } catch (error) {
      showError(`runtime/config.json could not be read, so the page has no theme (${error.message}).`);
      return null;
    }
    if (KITS.includes(kit)) return kit;
    showError(`runtime/config.json names no kit the runtime knows (${KITS.join(" or ")}), so the page has no theme.`);
    return null;
  }

  // 3. Tailwind compiles the theme from a <style type="text/tailwindcss">.
  // Plain CSS gets it as a stylesheet, which keeps url()s in it relative to
  // design-system/; it is fetched first all the same, so that a missing theme
  // is reported and the stylesheet comes from a fresh copy.
  async function addTheme(kit) {
    let css;
    try {
      css = await read("design-system/theme.css");
    } catch (error) {
      showError(`Missing theme: design-system/theme.css (${error.message})`);
      return;
    }
    if (kit === "tailwind4") {
      const style = document.createElement("style");
      style.setAttribute("type", "text/tailwindcss");
      style.textContent = css;
      document.head.append(style);
    } else {
      await new Promise((resolve) => {
        const link = document.createElement("link");
        link.rel = "stylesheet";
        link.href = new URL("design-system/theme.css", root).href;
        link.onload = resolve;
        link.onerror = () => {
          showError("Missing theme: design-system/theme.css");
          resolve();
        };
        document.head.append(link);
      });
    }
  }

  // 4. Round after round, since a component may hold includes of its own.
  async function resolveIncludes() {
    const cache = new Map();
    const load = (src) => {
      const url = new URL(src, root).href;
      if (!cache.has(url)) cache.set(url, read(url));
      return cache.get(url);
    };

    for (let round = 0; round < MAX_ROUNDS; round++) {
      const includes = document.querySelectorAll("x-include[src]");
      if (includes.length === 0) return;
      await Promise.all(Array.from(includes, (element) => include(element, load)));
    }
    for (const element of document.querySelectorAll("x-include[src]")) {
      const src = element.getAttribute("src");
      console.error(`Flosis: components nested more than ${MAX_ROUNDS} deep at ${src}`);
      element.replaceWith(errorBox(`Components nested more than ${MAX_ROUNDS} deep (does one include itself?): ${src}`));
    }
  }

  async function include(element, load) {
    const src = element.getAttribute("src");
    let html;
    try {
      if (!src.trim()) throw new Error("no src");
      html = await load(src);
    } catch (error) {
      console.error(`Flosis: missing component ${src} (${error.message})`);
      element.replaceWith(errorBox(`Missing component: ${src}`));
      return;
    }

    const template = document.createElement("template");
    template.innerHTML = html.replace(PLACEHOLDER, (_, name) => escapeHtml(element.getAttribute(name) ?? ""));
    // Before the children move in: they are the page's own markup, and their
    // paths stay relative to the page.
    resolvePaths(template.content);
    // The children take the slot's place, so the page's markup stays as written
    // (a wrapper would break child selectors such as Tailwind's space-y-*).
    const slot = template.content.querySelector("slot");
    if (slot) slot.replaceWith(...element.childNodes);
    element.replaceWith(template.content);
  }

  // A component's paths are relative to the repo root, so they mean the same
  // from every page: each relative src, href, srcset candidate and poster in it
  // becomes absolute. Nested includes keep their src, which already starts at
  // the root.
  function resolvePaths(fragment) {
    for (const element of fragment.querySelectorAll("[src], [href], [srcset], [poster]")) {
      if (element.localName === "x-include") continue;
      for (const name of ["src", "href", "poster"]) {
        if (element.hasAttribute(name)) element.setAttribute(name, fromRoot(element.getAttribute(name)));
      }
      if (element.hasAttribute("srcset")) element.setAttribute("srcset", srcsetFromRoot(element.getAttribute("srcset")));
    }
  }

  // Left as they are: URLs with a scheme (https:, mailto:, tel:, data:,
  // javascript:, …), //host and /path, and #… or ?…, which point into the
  // page itself.
  function fromRoot(value) {
    const path = value.trim();
    if (path === "" || /^([a-z][a-z\d+.-]*:|[/#?])/i.test(path)) return value;
    try {
      return new URL(path, root).href;
    } catch {
      return value;
    }
  }

  // Each candidate is a URL, an optional descriptor (2x, 480w), then a comma.
  // The URL runs to the first whitespace, as the HTML parser reads it, so a
  // comma inside a data: URL stays part of the URL.
  function srcsetFromRoot(srcset) {
    const candidates = [];
    let rest = srcset;
    for (;;) {
      rest = rest.replace(/^[\s,]+/, "");
      if (!rest) break;
      let url = rest.match(/^\S+/)[0];
      rest = rest.slice(url.length);
      let descriptor = "";
      if (url.endsWith(",")) {
        url = url.replace(/,+$/, "");
      } else {
        const end = rest.indexOf(",");
        descriptor = (end < 0 ? rest : rest.slice(0, end)).trim();
        rest = end < 0 ? "" : rest.slice(end + 1);
      }
      candidates.push(descriptor ? `${fromRoot(url)} ${descriptor}` : fromRoot(url));
    }
    return candidates.join(", ");
  }

  // 5.
  async function applyContexts() {
    const requested = (new URLSearchParams(location.search).get("ctx") ?? "")
      .split(",").map((value) => value.trim()).filter(Boolean);
    try {
      const { dimensions = [] } = JSON.parse(await read("designs/contexts.json"));
      for (const dimension of dimensions) {
        const ids = (dimension.values ?? []).map((value) => value.id);
        const active = requested.find((id) => ids.includes(id)) ??
          (ids.includes(dimension.default) ? dimension.default : ids[0]);
        if (active === undefined) continue;
        document.documentElement.setAttribute(`data-ctx-${dimension.id}`, active);
        Flosis.ctx[dimension.id] = active;
      }
    } catch (error) {
      showError(`designs/contexts.json could not be applied (${error.message}).`);
    }

    const active = Object.values(Flosis.ctx);
    const holdsActive = (list) => list.split(/\s+/).some((value) => active.includes(value));
    for (const element of document.querySelectorAll("[data-ctx-show]")) {
      if (!holdsActive(element.getAttribute("data-ctx-show"))) element.hidden = true;
    }
    for (const element of document.querySelectorAll("[data-ctx-hide]")) {
      if (holdsActive(element.getAttribute("data-ctx-hide"))) element.hidden = true;
    }
    // The hidden attribute loses to any display a stylesheet sets
    // (.row { display: flex }); a context must not.
    const style = document.createElement("style");
    style.textContent = "[data-ctx-show][hidden],[data-ctx-hide][hidden]{display:none!important}";
    document.head.append(style);
  }

  // 6. On click rather than up front, so links added later carry the context too.
  // The values are joined by a bare comma, as in the links Flosis writes.
  function carryContexts() {
    const values = Object.values(Flosis.ctx);
    const carry = (event) => {
      const link = event.target instanceof Element ? event.target.closest("a[href]") : null;
      const href = link?.getAttribute("href") ?? "";
      if (!link || href.startsWith("#")) return;

      let url;
      try {
        url = new URL(href, document.baseURI);
      } catch {
        return;
      }
      if (url.origin !== location.origin) return;

      const params = new URLSearchParams(url.search);
      params.delete("ctx");
      const ctx = values.length ? `ctx=${values.map(encodeURIComponent).join(",")}` : "";
      url.search = [params.toString(), ctx].filter(Boolean).join("&");
      link.setAttribute("href", url.href);
    };
    // auxclick: a middle click opens the link in a new tab.
    document.addEventListener("click", carry, true);
    document.addEventListener("auxclick", carry, true);
  }

  // 7.
  function loadKit() {
    return new Promise((resolve) => {
      const script = document.createElement("script");
      script.src = new URL("runtime/kit.js", root).href;
      script.onload = resolve;
      script.onerror = () => {
        showError("Missing runtime/kit.js, so the page is not styled.");
        resolve();
      };
      document.head.append(script);
    });
  }

  // no-cache: the browser checks with the server every time, so a component
  // changed since the last visit is never shown as it was.
  async function read(path) {
    const response = await fetch(new URL(path, root), { cache: "no-cache" });
    if (!response.ok) throw new Error(`${response.status} ${response.statusText}`.trim());
    return response.text();
  }

  function escapeHtml(text) {
    return text.replace(/[&<>"']/g, (char) => ESCAPES[char]);
  }

  function errorBox(message) {
    const box = document.createElement("div");
    box.setAttribute("data-flosis-error", "");
    box.setAttribute("style", "border:2px solid #c00;padding:8px");
    box.textContent = message;
    return box;
  }

  // An error that belongs to the whole page rather than to one place in it.
  function showError(message) {
    console.error(`Flosis: ${message}`);
    domReady.then(() => document.body.prepend(errorBox(message)));
  }
})();
