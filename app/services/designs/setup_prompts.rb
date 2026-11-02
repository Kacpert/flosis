# The first text of the three phase prompts of a setup run, which the
# AddDesignSetups migration seeds into the library (kind base_prompt). From
# then on the library is the source: staff edit them there, and a library
# without one falls back to this text (Designs::Library.compose_setup).
module Designs::SetupPrompts
  SEEDS = {
    "design_system" => {
      key: "setup-design-system", name: "Setup: design system",
      description: "Phase 1 of a setup run: the app's tokens, type, colour, logos and fonts.",
      body: <<~TEXT
        You are recreating an existing, running application in its design repo, in three phases. This is phase 1 of 3: the design system.

        This phase owns design-system/ and nothing else. Later phases build on what you leave here and must not undo it.

        - Read the tokens from the app's own CSS and theme files first (its stylesheets, Tailwind configuration and theme variables, in the read-only copy of the app). Then check each one against the computed styles in the crawl bundle, and say where they disagree.
        - Write them as the design system's tokens: colours, type scale, spacing, radii, shadows and breakpoints, named as the app names them.
        - Copy fonts and logos from the app or the materials. Never approximate them; when one cannot be found, list it as missing instead.
        - Document every token on design-system/index.html, as the template does.
      TEXT
    },
    "components" => {
      key: "setup-components", name: "Setup: components",
      description: "Phase 2 of a setup run: one component per real building block of the app.",
      body: <<~TEXT
        This is phase 2 of 3 of a setup run: the components.

        This phase owns components/. The design system from phase 1 stays as it is; use its tokens, never values of your own. Phase 3 will build every screen from what you leave here.

        - Find the app's real UI building blocks in its views, partials and front-end components (buttons, fields, tables, cards, navigation, modals, empty states...), and check them against the crawled pages.
        - Make one component per building block, in its own folder, with the states and variants the app uses.
        - Give each component a README with its guidelines (when to use it, its variants, what not to do), and a preview page that shows every variant.
        - Do not invent components the app does not have.
      TEXT
    },
    "designs" => {
      key: "setup-designs", name: "Setup: designs",
      description: "Phase 3 of a setup run: every crawled page, per role, as a screen.",
      body: <<~TEXT
        This is phase 3 of 3 of a setup run: the current screens.

        This phase owns designs/. Use only the components from phase 2 and the tokens from phase 1; when a screen needs something they lack, say so instead of drawing it ad hoc.

        - Each page the crawl visited becomes a screen under designs/, as it looked for each role that could see it.
        - Write designs/contexts.json with a "permissions" dimension whose values are the crawled role names, and show each screen's differences between roles through those contexts.
        - Link the screens to each other as the app's navigation does, so the designs can be clicked through.
      TEXT
    }
  }.freeze
end
