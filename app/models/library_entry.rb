# One entry of the design library — the base prompt, a skill or a style pack —
# kept by Flosis staff. Its text lives in its versions, numbered from 1 and
# never changed: editing makes a new version, restoring an old one makes a new
# version with the old text. A turn records the versions its prompt was made
# of, so entries are switched off (active false), never deleted.
class LibraryEntry < ApplicationRecord
  KINDS = %w[base_prompt skill style_pack].freeze

  has_many :library_entry_versions, -> { order(:number) }, inverse_of: :library_entry,
           dependent: :restrict_with_exception

  validates :kind, inclusion: { in: KINDS }
  validates :key, presence: true, uniqueness: true, format: { with: /\A[a-z0-9-]+\z/ }
  validates :name, presence: true

  scope :active, -> { where(active: true) }
  scope :of_kind, ->(kind) { where(kind: kind) }

  # The highest-numbered version, or nil for an entry with no text yet.
  def current_version
    library_entry_versions.reorder(number: :desc).first
  end

  # A new version with this text, stripped. Text the current version already
  # has makes none, and the current version comes back. The row lock keeps two
  # saves from taking the same number.
  def revise!(body:, by:)
    with_lock do
      text = body.to_s.strip
      current = current_version
      if current && current.body == text
        current
      else
        library_entry_versions.create!(number: current&.number.to_i + 1, body: text, created_by: by)
      end
    end
  end

  # The old version's text as a new version: history stays as it was.
  def restore!(version, by:)
    raise ArgumentError, "version #{version.id} belongs to another entry" unless version.library_entry_id == id

    revise!(body: version.body, by: by)
  end
end
