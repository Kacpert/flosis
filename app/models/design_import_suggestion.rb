# What an import needs from the person, or saw beyond what it was asked
# (Kacper, 2026-11-22: "jak AI nie miało danej roli czy coś"): a role the
# setup's contexts do not cover (context), a context that could not sign in
# (sign_in), anything else only the person can give (other). One per thing
# and import, by its key; a role the person dismissed is not raised again by
# a later import of the project. Its actions (Feedback, on the import's page)
# import more (Designs::ImportMore).
class DesignImportSuggestion < ApplicationRecord
  KINDS = %w[context sign_in other].freeze
  STATUSES = %w[open done dismissed].freeze

  belongs_to :design_setup
  belongs_to :role, class_name: "DesignSetupRole", foreign_key: :design_setup_role_id, optional: true
  belongs_to :acted_by, class_name: "User", optional: true

  # Production is MariaDB: the column reads as text unless typed here.
  attribute :features, :json, default: []

  validates :kind, inclusion: { in: KINDS }
  validates :status, inclusion: { in: STATUSES }
  validates :key, :title, presence: true

  scope :open, -> { where(status: "open") }

  # The suggestion for this thing on this import, made once; nil for a role
  # the person dismissed on an import of the project before. A login that
  # fails again, or anything else, comes back.
  def self.record!(setup, kind:, title:, detail: nil, context_name: nil, role: nil, features: [])
    key = key_for(kind, title: title, context_name: context_name, role: role)
    return if kind == "context" && joins(:design_setup).where(design_setups: { project_id: setup.project_id }).exists?(key: key, status: "dismissed")

    setup.suggestions.find_or_create_by!(key: key) do |suggestion|
      suggestion.assign_attributes(kind: kind, title: title.to_s.squish.truncate(200), detail: detail.to_s.strip.truncate(2_000).presence,
                                   context_name: context_name.to_s.squish.truncate(120).presence, role: role,
                                   features: Array(features).map(&:to_s).first(30))
    end
  rescue ActiveRecord::RecordNotUnique
    setup.suggestions.find_by!(key: key)
  end

  # The roles the person dismissed on any import of the project, for the
  # turns not to raise them again.
  def self.dismissed_contexts(project)
    joins(:design_setup).where(design_setups: { project_id: project.id }, kind: "context", status: "dismissed")
                        .where.not(context_name: nil).distinct.order(:context_name).pluck(:context_name)
  end

  def self.key_for(kind, title:, context_name:, role:)
    case kind
    when "context" then "context:#{context_name.to_s.parameterize.presence || title.to_s.parameterize.first(80)}"
    when "sign_in" then "sign_in:#{role&.id || context_name.to_s.parameterize}"
    else "other:#{title.to_s.parameterize.first(80)}"
    end
  end

  def act!(user, status)
    update!(status: status, acted_by: user, acted_at: Time.current)
  end
end
