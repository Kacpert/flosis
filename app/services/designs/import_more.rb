# Importing more after an import is over, from its Feedback (Kacper,
# 2026-11-22: "żeby po wykonaniu, dało się jeszcze doimportować"). The map
# stays one row per feature: a context the person added from a suggestion
# joins the map's features the suggestion names, each queued on this import
# under its own key (this import's row when it has one, else a new row from
# the map's), to be built again with it; with none named, one feature looks
# for that context's screens. A fixed login has what this import built from
# the code for that context checked against the app. The import's job builds
# what is queued, one feature a unit, each landing on master by itself.
class Designs::ImportMore
  # The most features one suggestion queues.
  MAX = 10

  def initialize(setup)
    @setup = setup
    @project = setup.project
  end

  # The features queued for role, a context the person added.
  def context!(role, suggestion)
    slug = Designs::SignIn.slug(role)
    words = "#{role.name} is a new context: build its screens. The other contexts' screens exist: update them only where they differ from the app."
    map = @project.design_feature_map.index_by(&:key)
    named = Array(suggestion.features).filter_map { |key| map[key.to_s] }.uniq(&:key).first(MAX)
    queued = named.any? ? named.map { |mapped| queue_with(mapped, slug, words) } : [ screens_of(role, slug, suggestion) ]
    @setup.start_work!
    queued
  end

  # The features this import built from the code for role, queued again now
  # that it can sign in.
  def fix_login!(role)
    slug = Designs::SignIn.slug(role)
    features = @setup.features.select { |feature| Array(feature.from_code).include?(slug) && !feature.running? }
    features.each do |feature|
      feature.queue!(reply: "#{role.name} can sign in now: check its screens against the app and fix what differs. They were built from the code.")
    end
    @setup.start_work! if features.any?
    features
  end

  private

  # The context joins the feature's contexts; a feature with none is every
  # context's already.
  def with(contexts, slug) = contexts.presence ? (contexts | [ slug ]) : []

  def queue_with(mapped, slug, words)
    own = @setup.features.find_by(key: mapped.key)
    # Being built: never queued again under its own build (final review I6).
    return own if own&.running?

    if own
      own.update!(contexts: with(own.contexts, slug))
      own.queue!(reply: words)
      own
    else
      @setup.features.create!(key: mapped.key, name: mapped.name, brief: mapped.brief, screens: mapped.screens, contexts: with(mapped.contexts, slug),
                              position: next_position, source: "changed", status: "todo", queued_at: Time.current, reply: words)
    end
  end

  def screens_of(role, slug, suggestion)
    name = "#{role.name}'s screens"
    @setup.features.create!(name: name, key: DesignSetupFeature.key_for(name, @setup.features.pluck(:key)), position: next_position,
                            source: "added", status: "todo", queued_at: Time.current, contexts: [ slug ],
                            brief: [ suggestion.detail.presence || suggestion.title, "Find what #{role.name} has in the app and build its screens." ].join("\n"))
  end

  def next_position = @setup.features.maximum(:position).to_i + 1
end
