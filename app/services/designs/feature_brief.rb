# What a setup run asks of Claude for one feature (the Designs setup, feature
# by feature): the feature as the map gave it, the contexts by the slugs the
# browser knows them by, its notes so far, and the features built before it.
# The setup-feature prompt says how to build it.
module Designs::FeatureBrief
  # A feature the person added from the import's page (Missing feature?).
  ADDED = " The person added it from the import's page. It is not on the map yet: find it in the app's code and in the app first.".freeze

  module_function

  def for(feature)
    setup = feature.design_setup
    roles = setup.project.design_setup_roles.index_by { |role| Designs::SignIn.slug(role) }
    contexts = feature.contexts.map { |slug| roles[slug] ? "#{roles[slug].name} (#{slug})" : slug }
    before = setup.features.where(status: "done").where.not(id: feature.id).pluck(:name)
    <<~TEXT
      Build the feature "#{feature.name}" (#{feature.position} of #{setup.features.size}).#{ADDED if feature.source == "added"}

      Contexts: #{contexts.join(', ').presence || 'every context'}
      Screens: #{feature.screens.join(', ').presence || 'as the brief says'}

      Brief:
      #{feature.brief.presence || '(none)'}

      Notes so far:
      #{feature.notes.map { |note| "- #{note}" }.join("\n").presence || '(none)'}

      Built before this one: #{before.join(', ').presence || 'nothing yet'}
    TEXT
  end
end
