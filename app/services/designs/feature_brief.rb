# What a setup run asks of Claude for one feature (the Designs setup, feature
# by feature): the feature as the map gave it, the contexts by the slugs the
# browser knows them by, its notes so far, and the features built before it.
# The setup-feature prompt says how to build it.
module Designs::FeatureBrief
  # A feature the person added from the import's page (Missing feature?).
  ADDED = " The person added it from the import's page. It is not on the map yet: find it in the app's code and in the app first.".freeze

  module_function

  # The first line: a feature to build, or (a resync's) one to bring in step
  # with the app, or one the app has that the map did not.
  def opening(feature, setup)
    of = "(#{feature.position} of #{setup.features.size})"
    case feature.source
    when "changed" then "Update the feature \"#{feature.name}\" #{of} to what the app has now."
    when "new" then "Build the feature \"#{feature.name}\" #{of}. It is new in the app since the last import."
    else "Build the feature \"#{feature.name}\" #{of}.#{ADDED if feature.source == 'added'}"
    end
  end

  def for(feature)
    setup = feature.design_setup
    roles = setup.project.design_setup_roles.index_by { |role| Designs::SignIn.slug(role) }
    contexts = feature.contexts.map { |slug| roles[slug] ? "#{roles[slug].name} (#{slug})" : slug }
    before = setup.features.where(status: "done").where.not(id: feature.id).pluck(:name)
    <<~TEXT
      #{opening(feature, setup)}

      Contexts: #{contexts.join(', ').presence || 'every context'}
      Screens: #{feature.screens.join(', ').presence || 'as the brief says'}

      Brief:
      #{feature.brief.presence || '(none)'}
      #{"\nWhat changed in its code since the last import:\n#{feature.code_changes}\n" if feature.code_changes.present?}
      Notes so far:
      #{feature.notes.map { |note| "- #{note}" }.join("\n").presence || '(none)'}

      Built before this one: #{before.join(', ').presence || 'nothing yet'}
    TEXT
  end
end
