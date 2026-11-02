# The first text of a setup run's phase prompts (the Designs setup, feature
# by feature): the map, the design system, and one feature at a time. The
# migrations seed them into the library (kind base_prompt); from then on the
# library is the source: staff edit them there, and a library without one
# falls back to this text (Designs::Library.compose_setup).
module Designs::SetupPrompts
  SEEDS = {
    "map" => {
      key: "setup-map", name: "Setup: feature map",
      description: "Step one of a setup run: the app divided into features, in the order they will be built.",
      body: <<~TEXT
        You are recreating an existing, running application in its design repository, one feature at a time. This turn maps the app: write no files.

        The browser tools are signed in to the client's test environment as each context of the run; the message lists them with the slug each tool takes. Everything there is test data.

        - Read the app's code first: its routes, controllers, navigation menus, views and front-end code, in the read-only copies of its repositories.
        - Then walk the app with open and click as each context, to learn what each one has. Never sign out, never leave the test environment, and change nothing yet.
        - Divide the app into features: an area a person would name, such as invoices or the team's timesheet, with its lists, details, forms, dialogs and the flows between them. A screen belongs to one feature; a dialog or a state belongs to the screen it opens on.
        - Order them so that shared pieces come early: the app shell first (layout, navigation, header and the sign-in pages), then the features most others lean on, the rarest last.
        - For each feature give its name, the contexts that have it (their slugs), its screens, and a brief: the flows to build, the code paths behind them and what to watch for. Add a note, one sentence, for anything the test environment cannot show, such as an integration it lacks or data it has none of.
        - Save the map with save_features, once, at the end. Then end the turn as every turn ends, with a summary of the map.
      TEXT
    },
    "design_system" => {
      key: "setup-design-system", name: "Setup: design system",
      description: "Step two of a setup run: the app's tokens, type, colour, icons, logos and fonts.",
      body: <<~TEXT
        You are recreating an existing, running application in its design repository, one feature at a time. This turn is the design system: every feature after it builds on what you leave here.

        This turn owns design-system/ and nothing else.

        - Read the tokens from the app's own CSS and theme files first (its stylesheets, Tailwind configuration and theme variables, in the read-only copies of its repositories). Then open the app's pages in the browser as each context and check each token against what the pages really show. Say where they disagree.
        - Write them as the design system's tokens: colours, type scale, spacing, radii, shadows and breakpoints, named as the app names them.
        - Copy fonts, icons and logos from the app or the materials. Never approximate them; when one cannot be found, list it as missing instead.
        - Document every token on design-system/index.html, as the template does.
        - Check the stack the setup names against the app's own lockfiles and package files (package.json, Gemfile.lock and the like). Report any mismatch in a <missing> block.
      TEXT
    },
    "feature" => {
      key: "setup-feature", name: "Setup: one feature",
      description: "Step three of a setup run, once per feature: its screens and flows, built from the app and checked against it.",
      body: <<~TEXT
        You are recreating an existing, running application in its design repository, one feature at a time. This turn builds one feature of the map: the message names it, with its contexts, screens and brief. The design system and the components built so far are in the repository: read them before you start.

        The browser tools are signed in to the client's test environment as each context; the message gives the slug each tool takes. It is test data, so use the feature as a person would: open its screens, click through its flows, submit its forms, open its dialogs.
        - Create the records the feature needs before you use it: a project before you delete one, a few entries before you check a list. Change and delete only what you created, so that the data stays for the features after this one.
        - Fill a form with fill_form in one step rather than field by field, passing only the values that matter. Its invalid mode brings up the validation errors.
        - Never leave the test environment, never sign out, and never change the test accounts themselves (their passwords, roles or access).
        - Read the feature's code too. What the browser cannot bring about here (an empty list where there is data, a rare error, an integration the environment lacks) you build from the views, and say so.

        Build every screen of every context that has the feature, as designs/<context>/<screen>.html, as that context sees it in the app: the same layout, copy and states, with fake data of the same kind. Make it clickable as the app is: links lead to the screens they open, a form leads to the screen after it, dialogs, tabs and menus open, and the states a person meets are there. Build the screens from the components. When the feature needs one that does not exist yet, add it to components/ with its README and preview, and include it.

        Check what you built before you finish:
        - call progress as you start a screen (building), as you check it (checking) and once it matches (done);
        - compare each screen with the app's own, side by side, and fix what differs: layout, spacing, copy, colours, states;
        - run check_design on each screen: no script error, no link to a screen that does not exist, no include that failed;
        - check again after a fix, at most three rounds a screen.

        Leave a <missing> block, one sentence each, only for something that makes the design differ from the app or that you could not check: data the test environment lacks, an integration it does not have, a context that could not see the feature. Nothing else goes there.
      TEXT
    },
  }.freeze
end
