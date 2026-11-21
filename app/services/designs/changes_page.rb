require "cgi"

# The page a task's lasting link opens with no page named (2026-11-21): what
# its thread changed, per context, new and updated, each screen linking to its
# page and to its changes marked up (<screen>.changes.html). It is published
# as __flosis/changes.html beside the screens, so its links are relative.
# Static, with no script: the preview serves it sandboxed like any page.
module Designs::ChangesPage
  module_function

  KINDS = [ [ "New", "new" ], [ "Updated", "updated" ] ].freeze

  # own: [[context, screen, kind]]; through: { component => [[context, screen]] };
  # screens: the slot's screens.json ({ "contexts" => [...], "screens" => [...] }).
  def render(title:, status:, own:, through:, screens:)
    contexts = Array(screens["contexts"]).to_h { |context| [ context["id"], context["name"] ] }
    names = Array(screens["screens"]).to_h { |screen| [ [ screen["context"], screen["id"] ], screen["name"] ] }
    sections = own.group_by(&:first).map do |context, changes|
      groups = KINDS.filter_map do |label, kind|
        items = changes.select { |change| change[2] == kind }
        next if items.empty?

        "<h3>#{label}</h3><ul>#{items.map { |_, screen, _| item(context, screen, names) }.join}</ul>"
      end
      "<section><h2>#{h(contexts[context] || context.to_s.humanize)}</h2>#{groups.join}</section>"
    end
    shared = through.keys.map { |name| name.to_s.tr("-_", "  ") }
    <<~HTML
      <!doctype html>
      <html lang="en">
      <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>#{h(title)}</title>
      <style>
        body { margin: 0; font: 15px/1.55 system-ui, -apple-system, "Segoe UI", Roboto, sans-serif; color: #111827; background: #fafafa; }
        main { max-width: 760px; margin: 0 auto; padding: 32px 20px 56px; }
        h1 { font-size: 22px; margin: 0 0 4px; letter-spacing: -0.2px; }
        .status { color: #6b7280; margin: 0 0 24px; font-size: 13px; }
        section { background: #fff; border: 1px solid rgba(0, 0, 0, 0.08); border-radius: 12px; padding: 14px 18px; margin-bottom: 14px; }
        h2 { font-size: 15px; margin: 0 0 6px; }
        h3 { font-size: 11px; font-weight: 700; letter-spacing: .5px; text-transform: uppercase; color: #6b7280; margin: 12px 0 4px; }
        ul { margin: 0; padding: 0; list-style: none; }
        li { padding: 4px 0; }
        a { color: #4338ca; text-decoration: none; }
        a:hover { text-decoration: underline; }
        a.changes { color: #9aa3af; font-size: 12px; margin-left: 8px; }
        .through { color: #6b7280; font-size: 13px; }
      </style>
      </head>
      <body>
      <main>
      <h1>#{h(title)}</h1>
      <p class="status">#{h(status)}</p>
      #{sections.join("\n")}
      #{shared.any? ? %(<p class="through">Through shared components: #{h(shared.join(', '))}</p>) : ''}
      </main>
      </body>
      </html>
    HTML
  end

  def item(context, screen, names)
    page = "../designs/#{context}/#{screen}"
    %(<li><a href="#{h(page)}.html">#{h(names[[ context, screen ]] || screen.to_s.humanize)}</a>) +
      %(<a class="changes" href="#{h(page)}.changes.html">changes</a></li>)
  end

  def h(text) = CGI.escapeHTML(text.to_s)
end
