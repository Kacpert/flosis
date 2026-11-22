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
//   5. tells the Designs canvas around it which screen this is: a screen is
//      designs/<context>/<screen>.html, or its Changes view,
//      designs/<context>/<screen>.changes.html;
//   6. turns a click on a screen that is not designed into a message to the
//      canvas instead, from the screens Flosis publishes beside the branch
//      (__flosis/screens.json; opened anywhere else, links are left alone);
//   7. outlines what Flosis marked for Changes (data-flosis-change);
//   8. loads the kit's runtime/kit.js last, so that it sees the finished page;
//   9. shows the page, hidden from the moment this script ran, once the kit
//      has styled it;
//  10. opened in a tab of its own, not inside the canvas, gives a screen a
//      small bar to step through the thread's changed screens and list them;
//  11. before 10, puts the screen in the state its hash names (see states());
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
  // What says which state an element belongs to. On an <x-include> they pass
  // to the component's own top-level elements.
  const STATE_ATTRIBUTES = ["data-show-in", "data-hide-in", "data-open-in"];
  const STATE_KEY = /^[A-Za-z0-9_-]+$/;
  // The page as it opens, with no state in its hash.
  const DEFAULT_STATE = "default";

  // The page is hidden until it is finished: its parts, its theme and the
  // kit's styles all arrive after the browser's first paint, and a click
  // through the designs showed half a second of unstyled text before them. A
  // page still unfinished after SHOW_AFTER_MS is shown all the same.
  const SHOW_AFTER_MS = 3000;
  const veil = document.createElement("style");
  veil.textContent = "html{visibility:hidden}";
  document.head.append(veil);
  const showAnyway = setTimeout(show, SHOW_AFTER_MS);
  function show() {
    clearTimeout(showAnyway);
    veil.remove();
  }

  // 1. Read now: currentScript is only set while this script first runs.
  const root = new URL("..", document.currentScript.src).href;

  const domReady = new Promise((resolve) => {
    if (document.readyState === "loading") {
      document.addEventListener("DOMContentLoaded", resolve, { once: true });
    } else {
      resolve();
    }
  });

  const Flosis = (window.Flosis = { root, context: null, screen: null, state: DEFAULT_STATE });
  const SCREEN_PATH = /^designs\/([A-Za-z0-9_-]+)\/([A-Za-z0-9_-]+)(?:\.changes)?\.html$/;
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
      reportScreen();
      await guardLinks();
      outlineChanges();
      states();
      await navigator().catch(() => {});
      if (kit === "tailwind4") {
        await loadKit();
        await kitStyled();
      }
    } catch (error) {
      showError(`The Flosis runtime stopped: ${error.message}`);
    } finally {
      show();
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
    for (const name of STATE_ATTRIBUTES) {
      if (!element.hasAttribute(name)) continue;
      for (const part of template.content.children) part.setAttribute(name, element.getAttribute(name));
    }
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

  // 5. The path from the repo's root names the screen; any other page is none.
  function screenAt(pathname) {
    const rootPath = new URL(root).pathname;
    if (!(pathname || "").startsWith(rootPath)) return null;
    let path;
    try {
      path = decodeURIComponent(pathname.slice(rootPath.length));
    } catch {
      return null;
    }
    const match = SCREEN_PATH.exec(path);
    return match ? { context: match[1], screen: match[2] } : null;
  }

  // The canvas is another origin (the preview is sandboxed), so it hears
  // messages only: "*" since an opaque origin has no name to address.
  function tellCanvas(message) {
    if (window.parent && window.parent !== window) window.parent.postMessage(message, "*");
  }

  function reportScreen() {
    const current = screenAt(location.pathname);
    if (!current) return;
    Flosis.context = current.context;
    Flosis.screen = current.screen;
    tellCanvas({ type: "flosis:screen", context: current.context, screen: current.screen, title: document.title || "" });
  }

  // 6. A screen missing in this context but designed in another is
  // "other-context"; one designed nowhere is "not-designed".
  async function guardLinks() {
    let screens;
    try {
      ({ screens = [] } = JSON.parse(await read("__flosis/screens.json")));
    } catch {
      return;
    }
    document.addEventListener("click", (event) => {
      const link = event.target instanceof Element ? event.target.closest("a[href]") : null;
      if (!link) return;
      let url;
      try {
        url = new URL(link.getAttribute("href"), document.baseURI);
      } catch {
        return;
      }
      // A link into the page itself (a state, an anchor) is not a screen to check.
      if (url.origin === location.origin && url.pathname === location.pathname) return;
      const target = url.origin === location.origin ? screenAt(url.pathname) : null;
      if (!target || screens.some((s) => s.context === target.context && s.id === target.screen)) return;

      event.preventDefault();
      tellCanvas({
        type: "flosis:missing",
        label: link.textContent.trim(),
        reason: screens.some((s) => s.id === target.screen) ? "other-context" : "not-designed",
        context: Flosis.context ?? target.context,
      });
    }, true);
  }

  // 10. Opened in a tab of its own, not inside the Designs canvas (which has
  // its own controls), a screen gets a small bar: ‹ › through the screens the
  // thread changed itself (__flosis/changes.json), or through its context's
  // screens when there are none, and ☰ for a list of those and of every
  // screen (Kacper, 2026-11-19). A convenience: what it cannot read, it leaves out.
  async function navigator() {
    if (window.top !== window) return;
    const current = screenAt(location.pathname);
    if (!current) return;

    const { screens = [], contexts = [] } = JSON.parse(await read("__flosis/screens.json"));
    let own = [];
    try {
      own = (JSON.parse(await read("__flosis/changes.json")).own || []).map(([context, screen]) => ({ context, screen }));
    } catch {}
    const changesView = /\.changes\.html$/.test(location.pathname);
    const same = (a, b) => a.context === b.context && a.screen === b.screen;
    const name = (entry) => screens.find((s) => s.context === entry.context && s.id === entry.screen)?.name || entry.screen;
    const contextName = (id) => contexts.find((c) => c.id === id)?.name || id;
    const href = (entry) =>
      new URL(`designs/${entry.context}/${entry.screen}${changesView && own.some((o) => same(o, entry)) ? ".changes" : ""}.html`, root).href;
    const steps = own.length ? own : screens.filter((s) => s.context === current.context).map((s) => ({ context: s.context, screen: s.id }));
    const at = steps.findIndex((step) => same(step, current));

    const style = document.createElement("style");
    style.textContent =
      ".flosis-nav{position:fixed;left:50%;bottom:16px;transform:translateX(-50%);z-index:2147483000;display:flex;align-items:center;gap:8px;" +
      "padding:6px 8px;border-radius:999px;background:#111827;color:#f9fafb;font:500 12.5px/1.2 system-ui,sans-serif;box-shadow:0 8px 24px rgba(0,0,0,.25)}" +
      ".flosis-nav a,.flosis-nav button{display:inline-flex;align-items:center;justify-content:center;width:26px;height:26px;border:0;border-radius:999px;" +
      "background:rgba(255,255,255,.12);color:#f9fafb;font:600 14px/1 system-ui,sans-serif;text-decoration:none;cursor:pointer}" +
      ".flosis-nav a:hover,.flosis-nav button:hover{background:rgba(255,255,255,.24)}" +
      ".flosis-nav-name{max-width:40vw;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}.flosis-nav-count{color:#9ca3af}" +
      ".flosis-nav-list{position:fixed;left:50%;bottom:60px;transform:translateX(-50%);z-index:2147483000;width:min(420px,92vw);max-height:60vh;" +
      "overflow:auto;padding:10px 12px;border-radius:12px;background:#fff;color:#111827;font:500 13px/1.35 system-ui,sans-serif;" +
      "box-shadow:0 12px 32px rgba(0,0,0,.25)}.flosis-nav-list[hidden]{display:none}" +
      ".flosis-nav-list h4{margin:10px 0 4px;font:700 10.5px/1 system-ui,sans-serif;letter-spacing:.05em;color:#6b7280;text-transform:uppercase}" +
      ".flosis-nav-list a{display:block;padding:5px 8px;border-radius:7px;color:#111827;text-decoration:none}" +
      ".flosis-nav-list a:hover{background:#f3f4f6}.flosis-nav-list a[aria-current]{background:#ede9fe;color:#5b21b6}" +
      ".flosis-nav-list input{display:block;box-sizing:border-box;width:100%;margin:0 0 4px;padding:6px 9px;border:1px solid #e5e7eb;" +
      "border-radius:7px;background:#fff;color:#111827;font:inherit}.flosis-nav-list [hidden]{display:none}";
    document.head.append(style);

    const list = document.createElement("div");
    list.className = "flosis-nav-list";
    list.setAttribute("data-flosis-nav-list", "");
    list.hidden = true;
    // A thread can reach hundreds of screens: the list filters by name.
    const filter = document.createElement("input");
    filter.type = "search";
    filter.placeholder = "Filter screens";
    filter.addEventListener("input", () => {
      const query = filter.value.trim().toLowerCase();
      for (const group of list.querySelectorAll("section")) {
        const links = [ ...group.querySelectorAll("a") ];
        for (const link of links) link.hidden = query !== "" && !link.textContent.toLowerCase().includes(query);
        group.hidden = links.every((link) => link.hidden);
      }
    });
    list.append(filter);
    const section = (title, entries) => {
      if (entries.length === 0) return;
      const group = document.createElement("section");
      const heading = document.createElement("h4");
      heading.textContent = title;
      group.append(heading);
      for (const entry of entries) {
        const link = document.createElement("a");
        link.href = href(entry);
        link.textContent = name(entry);
        if (same(entry, current)) link.setAttribute("aria-current", "page");
        group.append(link);
      }
      list.append(group);
    };
    const byContext = (entries) => [ ...new Set(entries.map((entry) => entry.context)) ].map((id) => [ id, entries.filter((e) => e.context === id) ]);
    for (const [id, entries] of byContext(own)) section(`Changed · ${contextName(id)}`, entries);
    for (const [id, entries] of byContext(screens.map((s) => ({ context: s.context, screen: s.id })))) section(contextName(id), entries);

    const bar = document.createElement("div");
    bar.className = "flosis-nav";
    bar.setAttribute("data-flosis-nav", "");
    const link = (text, entry, attribute, title) => {
      const a = document.createElement("a");
      a.textContent = text;
      a.href = href(entry);
      a.title = title;
      a.setAttribute(attribute, "");
      return a;
    };
    const label = document.createElement("span");
    label.className = "flosis-nav-name";
    label.textContent = `${contextName(current.context)} › ${name(current)}`;
    const count = document.createElement("span");
    count.className = "flosis-nav-count";
    count.textContent = `${at < 0 ? "–" : at + 1} / ${steps.length}`;
    const toggle = document.createElement("button");
    toggle.type = "button";
    toggle.textContent = "☰";
    toggle.title = "All screens";
    toggle.setAttribute("data-flosis-list", "");
    toggle.addEventListener("click", () => {
      list.hidden = !list.hidden;
      if (!list.hidden) filter.focus();
    });
    if (steps.length > 0) {
      bar.append(link("‹", steps[at <= 0 ? steps.length - 1 : at - 1], "data-flosis-prev", own.length ? "Previous changed screen" : "Previous screen"));
    }
    bar.append(label, count);
    if (steps.length > 0) {
      bar.append(link("›", steps[at < 0 || at === steps.length - 1 ? 0 : at + 1], "data-flosis-next", own.length ? "Next changed screen" : "Next screen"));
    }
    bar.append(toggle);
    document.body.append(list, bar);
  }

  // 11. A screen's states (Kacper, 2026-11-22): one file per page of the app,
  // with its states inside it, so that a change is made once. <nav data-states>
  // lists them: its first link is the page as it opens (href="#"), each other
  // one a state by its hash (consumption.html#over-limit). The nav is never
  // part of the page: inside the Designs canvas the states are told to the
  // canvas, which shows them in its own bar and picks one by a message; in a
  // tab of its own a small bar at the top switches them, except in a browser
  // driven by a test or a check, whose screenshots show the page alone. In a
  // state,
  //   data-show-in="a b"  shows an element only in those states ("default" is
  //                       the page as it opens);
  //   data-hide-in="a b"  hides it in those states;
  //   data-open-in="a"    opens what the page opens and closes itself (a dialog,
  //                       a drawer, a menu): its hidden class and attribute go,
  //                       and come back once the state is left;
  // and Flosis.state and a "flosis:state" event on document tell the page's own
  // script, for anything else. A hash that names no state (an anchor into the
  // page) leaves the state as it is.
  function states() {
    const nav = document.querySelector("nav[data-states]");
    if (!nav) return;
    nav.hidden = true;
    const list = [];
    for (const link of nav.querySelectorAll("a[href^='#']")) {
      const key = hashState(link.getAttribute("href")) ?? DEFAULT_STATE;
      if (STATE_KEY.test(key) && !list.some((state) => state.key === key)) {
        list.push({ key, label: link.textContent.trim() || key });
      }
    }
    if (!list.some((state) => state.key === DEFAULT_STATE)) list.unshift({ key: DEFAULT_STATE, label: document.title || "Default" });
    const named = (hash) => {
      const key = hashState(hash) ?? DEFAULT_STATE;
      return list.some((state) => state.key === key) ? key : null;
    };

    // What a state opened looked like closed, to close it again as it was.
    const opened = new Map();
    const bar = window.top === window && !window.navigator.webdriver ? switcher(list) : null;
    // Opened or closed first, then shown or hidden: an element both opened in
    // a state and shown only in some is hidden in the others whatever its
    // opening left behind.
    const apply = (key) => {
      Flosis.state = key;
      for (const element of document.querySelectorAll("[data-open-in]")) {
        if (words(element, "data-open-in").includes(key)) {
          if (!opened.has(element)) opened.set(element, { hiddenClass: element.classList.contains("hidden"), hidden: element.hidden });
          element.classList.remove("hidden");
          element.hidden = false;
        } else if (opened.has(element)) {
          const closed = opened.get(element);
          opened.delete(element);
          element.classList.toggle("hidden", closed.hiddenClass);
          element.hidden = closed.hidden;
        }
      }
      for (const element of document.querySelectorAll("[data-show-in]")) element.hidden = !words(element, "data-show-in").includes(key);
      for (const element of document.querySelectorAll("[data-hide-in]")) element.hidden = words(element, "data-hide-in").includes(key);
      for (const link of bar?.querySelectorAll("a") ?? []) {
        if (link.dataset.state === key) link.setAttribute("aria-current", "true");
        else link.removeAttribute("aria-current");
      }
      tellCanvas({ type: "flosis:states", states: list, state: key });
    };

    apply(named(location.hash) ?? DEFAULT_STATE);
    window.addEventListener("hashchange", () => {
      const key = named(location.hash);
      if (key === null || key === Flosis.state) return;
      apply(key);
      document.dispatchEvent(new CustomEvent("flosis:state", { detail: { state: key } }));
    });
    window.addEventListener("message", (event) => {
      if (event.source !== window.parent || event.data?.type !== "flosis:set-state") return;
      const key = named(`#${event.data.state === DEFAULT_STATE ? "" : event.data.state}`);
      if (key !== null) location.hash = key === DEFAULT_STATE ? "" : key;
    });
  }

  // The state a hash names, "" and "#" being none.
  function hashState(hash) {
    let key;
    try {
      key = decodeURIComponent((hash || "").replace(/^#/, ""));
    } catch {
      return undefined;
    }
    return key === "" ? null : key;
  }

  function words(element, name) {
    return (element.getAttribute(name) || "").split(/\s+/).filter(Boolean);
  }

  function switcher(list) {
    const style = document.createElement("style");
    style.textContent =
      ".flosis-states{position:fixed;top:8px;left:50%;transform:translateX(-50%);z-index:2147483000;display:flex;flex-wrap:wrap;" +
      "justify-content:center;gap:2px;max-width:calc(100vw - 32px);padding:3px;border-radius:999px;background:rgba(17,24,39,.88);" +
      "box-shadow:0 6px 18px rgba(0,0,0,.2);font:500 12px/1.2 system-ui,sans-serif}" +
      ".flosis-states a{padding:5px 10px;border-radius:999px;color:#e5e7eb;text-decoration:none;white-space:nowrap}" +
      ".flosis-states a:hover{background:rgba(255,255,255,.14)}.flosis-states a[aria-current]{background:#fff;color:#111827}";
    document.head.append(style);
    const bar = document.createElement("nav");
    bar.className = "flosis-states";
    bar.setAttribute("data-flosis-states", "");
    bar.setAttribute("aria-label", "States of this screen");
    for (const state of list) {
      const link = document.createElement("a");
      link.href = state.key === DEFAULT_STATE ? "#" : `#${state.key}`;
      link.dataset.state = state.key;
      link.textContent = state.label;
      bar.append(link);
    }
    document.body.append(bar);
    return bar;
  }

  // 7. The dashed purple outline and its NEW or UPDATED label, as the design
  // draws them. The page's <body> is marked when the whole screen is new.
  function outlineChanges() {
    const marked = document.querySelectorAll("[data-flosis-change]");
    if (marked.length === 0) return;
    for (const element of marked) {
      element.setAttribute("data-flosis-label", element.getAttribute("data-flosis-change") === "new" ? "NEW" : "UPDATED");
    }
    const style = document.createElement("style");
    style.textContent =
      "[data-flosis-change]{outline:2px dashed #7c3aed!important;outline-offset:4px;border-radius:4px;position:relative}" +
      "[data-flosis-change]::after{content:attr(data-flosis-label);position:absolute;top:-14px;right:8px;z-index:2;" +
      "font:700 10px/1.4 'Instrument Sans',system-ui,sans-serif;letter-spacing:.4px;color:#fff;background:#7c3aed;" +
      "padding:2px 7px;border-radius:5px;pointer-events:none}" +
      "body[data-flosis-change]{outline-offset:-4px}body[data-flosis-change]::after{top:6px}";
    document.head.append(style);
  }

  // 8.
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

  // Tailwind's browser build compiles the page's styles a moment after kit.js
  // loads and writes them, its banner first, into a <style>: the page is
  // shown once that banner is in. A kit that never writes it is waited for
  // no longer than SHOW_AFTER_MS.
  function kitStyled() {
    const started = Date.now();
    const styled = () => Array.from(document.querySelectorAll("style"), (style) => style.textContent)
      .some((css) => css.includes("! tailwindcss v"));
    return new Promise((resolve) => {
      const check = () => (styled() || Date.now() - started > SHOW_AFTER_MS ? resolve() : setTimeout(check, 16));
      check();
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
