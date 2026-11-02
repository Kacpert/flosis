# What a design turn's system prompt is made of, from the design library: the
# base prompt, then every active skill (in key order), then the project's style
# pack when it names an active one. Each piece is the current version of its
# entry, under a heading.
#
# A turn composes once (Ruling P3-R1). The text goes to Claude, the texts to
# the leak guard as what no design may quote, and the version ids onto the
# turn: what Claude was given is recorded in Flosis, never in the design repo.
module Designs::Library
  Composition = Data.define(:text, :texts, :version_ids)

  BASE_KEY = "designs-base".freeze

  Piece = Data.define(:heading, :body, :version_id)

  module_function

  def compose(project)
    composition_of([ base, *skills, style_pack(project) ].compact)
  end

  # A setup run's composition: the base prompt and the prompt of the run's
  # phase (Designs::SetupPrompts names them); no skills and no style pack, as
  # the run recreates the app as it is. A phase prompt missing from the library
  # falls back to the text it was seeded with, recording no version.
  def compose_setup(phase)
    seed = Designs::SetupPrompts::SEEDS.fetch(phase)
    entry = LibraryEntry.of_kind("base_prompt").find_by(key: seed[:key])
    version = entry&.current_version
    heading = "# Setup phase: #{entry&.name || seed[:name]}"
    phase_piece = version ? piece(heading, version) : Piece.new(heading: heading, body: seed[:body].strip, version_id: nil)
    composition_of([ base, phase_piece ])
  end

  def composition_of(pieces)
    Composition.new(
      text: pieces.map { |piece| "#{piece.heading}\n#{piece.body}" }.join("\n\n"),
      texts: pieces.map(&:body),
      version_ids: pieces.filter_map(&:version_id)
    )
  end

  # The base prompt carries the rules every turn needs, so it is used whether
  # or not it is switched on. A library with none (its versions gone) falls
  # back to the built-in prompt it was seeded from, which records no version.
  def base
    version = LibraryEntry.of_kind("base_prompt").find_by(key: BASE_KEY)&.current_version
    return piece("# Base", version) if version

    Piece.new(heading: "# Base", body: Designs::Prompt::BASE.strip, version_id: nil)
  end

  def skills
    LibraryEntry.active.of_kind("skill").order(:key).filter_map do |skill|
      version = skill.current_version
      piece("# Skill: #{skill.name}", version) if version
    end
  end

  def style_pack(project)
    key = project.design_style_pack_key.presence
    pack = key && LibraryEntry.active.of_kind("style_pack").find_by(key: key)
    version = pack&.current_version
    piece("# Style pack: #{pack.name}", version) if version
  end

  def piece(heading, version)
    Piece.new(heading: heading, body: version.body, version_id: version.id)
  end
end
