# The setup's progress screen (the Designs setup, feature by feature), as the
# mockup Kacper approved draws it: the steps with their times, the notes for
# him, and every feature of the map with where it stands.
module DesignSetupRunsHelper
  # "38 min", "1 h 5 min", "6 h".
  def setup_duration(minutes)
    minutes = minutes.to_i
    return "#{minutes} min" if minutes < 60

    hours, rest = minutes.divmod(60)
    rest.zero? ? "#{hours} h" : "#{hours} h #{rest} min"
  end

  # A feature's line under its name: "Admin, Member · 4 screens · 9 new
  # components"; one not started yet has "about" its screens.
  def setup_feature_sub(feature, names)
    contexts = feature.contexts.map { |slug| names.fetch(slug, slug) }.join(", ").presence || "Every context"
    count = feature.screens.size
    screens = "#{'about ' if feature.status == 'todo'}#{count} #{count == 1 ? 'screen' : 'screens'}"
    [ contexts, screens, (setup_components(feature) if feature.done?) ].compact.join(" · ")
  end

  # "9 new components", "1 new component, 6 reused", "9 components reused".
  def setup_components(feature)
    added, reused = feature.components_new, feature.components_reused
    return if added.zero? && reused.zero?
    return "#{reused} #{reused == 1 ? 'component' : 'components'} reused" if added.zero?

    made = "#{added} new #{added == 1 ? 'component' : 'components'}"
    reused.zero? ? made : "#{made}, #{reused} reused"
  end

  # Where a feature is, as a note's label says it.
  def setup_feature_state(feature, up_next)
    case feature.status
    when "done" then "DONE"
    when "running" then "IN PROGRESS"
    when "failed" then "COULDN'T FINISH"
    else feature == up_next ? "UP NEXT" : "TO DO"
    end
  end

  # The notes for him: the run's own first, then each feature's, labelled with
  # the feature and where it is.
  def setup_notes(setup, features, up_next)
    own = setup.notes.map { |note| [ note["label"].to_s.upcase, note["text"].to_s ] }
    own + features.flat_map do |feature|
      feature.notes.map { |text| [ "#{feature.name.upcase} · #{setup_feature_state(feature, up_next)}", text ] }
    end
  end

  # The pill's colours, from the theme's tokens.
  def setup_pill_style(feature)
    tone = if feature.failed? then "danger"
           elsif feature.running? then "ai"
           elsif feature.done? then feature.notes.empty? ? "success" : "warn"
           end
    tone ? "background: var(--#{tone}-soft); color: var(--#{tone});" : "background: var(--surface-2); color: var(--faint);"
  end

  # The screens of the feature being built, the map's and those the progress
  # names, each with where it stands: [[screen, status]].
  def setup_screens(feature, progress)
    (feature.screens | progress.keys).map { |screen| [ screen, progress.fetch(screen, "todo") ] }
  end
end
