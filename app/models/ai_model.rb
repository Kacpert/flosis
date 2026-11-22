# The reference price list (Models & prices): what Anthropic charges per 1M
# tokens, in US dollars, read daily (AiPriceRead) or typed by hand when a read
# fails. Runs are never priced from it: a run's cost is what the CLI reported.
class AiModel < ApplicationRecord
  # The current family, listed before any run has used it.
  SEED = %w[claude-opus-5-5 claude-sonnet-5-5 claude-haiku-5-5].freeze

  has_many :ai_plan_models, dependent: :destroy
  has_many :ai_plans, through: :ai_plan_models

  validates :model_id, presence: true, uniqueness: true
  validates :name, presence: true
  validates :price_source, inclusion: { in: %w[read hand] }

  # "claude-opus-5-5" → "Claude Opus 5.5"; a release date at the end is dropped.
  def self.name_for(model_id)
    words = normalize_id(model_id).to_s.sub(/-\d{8}\z/, "").split("-")
    family = words.take_while { |word| word !~ /\A\d+\z/ }
    version = words.drop(family.size)
    [ family.map(&:capitalize).join(" "), version.join(".").presence ].compact.join(" ")
  end

  # The CLI may name a model with its context window: "claude-opus-5[1m]".
  def self.normalize_id(raw)
    raw&.to_s&.sub(/\[[^\]]*\]\z/, "")&.strip.presence
  end

  def self.seed!
    SEED.each { |model_id| register!(model_id) }
  end

  def self.register!(raw)
    model_id = normalize_id(raw)
    return unless model_id

    find_or_create_by!(model_id: model_id) { |model| model.name = name_for(model_id) }
  rescue ActiveRecord::RecordNotUnique
    find_by(model_id: model_id)
  end

  def in_use?
    ai_plan_models.exists?
  end
end
