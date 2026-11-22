require "net/http"

# The daily read of Anthropic's prices into Models & prices (SCRUM-70).
# Anthropic publishes no price API, so the prices come from LiteLLM's public,
# machine-readable price list (USD per token), kept as USD per 1M tokens. A
# model the list lacks, or a read that fails, keeps the price it had and is
# marked failed — that is when staff type one by hand. A successful read
# overwrites a typed price. The list is for reading only: a run is priced from
# the cost the CLI reported, never from it.
class AiPriceRead
  URL = "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json".freeze
  FIELDS = {
    input_usd_per_mtok: "input_cost_per_token",
    output_usd_per_mtok: "output_cost_per_token",
    cache_write_usd_per_mtok: "cache_creation_input_token_cost",
    cache_read_usd_per_mtok: "cache_read_input_token_cost"
  }.freeze

  def initialize(fetch: ->(url) { Net::HTTP.get(URI(url)) })
    @fetch = fetch
  end

  # { updated:, failed: } — how many models got a price and how many did not.
  def call
    AiModel.seed!
    models = AiModel.order(:model_id).to_a
    prices = fetch_prices
    return mark_failed(models) unless prices

    updated = 0
    models.each do |model|
      entry = entry_for(prices, model.model_id)
      if entry && (values = price_values(entry)).any?
        model.update!(values.merge(price_source: "read", read_at: Time.current))
        updated += 1
      else
        model.update!(read_failed_at: Time.current)
      end
    end
    { updated: updated, failed: models.size - updated }
  end

  private

  def fetch_prices
    data = JSON.parse(@fetch.call(URL).to_s)
    data.is_a?(Hash) ? data : nil
  rescue StandardError => e
    Rails.logger.warn("[AiPriceRead] the price list could not be read: #{e.class}: #{e.message}")
    nil
  end

  def mark_failed(models)
    models.each { |model| model.update!(read_failed_at: Time.current) }
    { updated: 0, failed: models.size }
  end

  # The model's own key, its anthropic/ key, else the newest dated key for it.
  # Only Anthropic's own entries count: Bedrock or Vertex prices differ.
  def entry_for(prices, model_id)
    anthropic = ->(entry) { entry.is_a?(Hash) && entry["litellm_provider"] == "anthropic" }
    [ model_id, "anthropic/#{model_id}" ].each { |key| return prices[key] if anthropic.call(prices[key]) }

    dated = prices.keys.grep(/\A(anthropic\/)?#{Regexp.escape(model_id)}-\d{8}\z/).sort.reverse
    dated.map { |key| prices[key] }.find(&anthropic)
  end

  def price_values(entry)
    FIELDS.filter_map do |column, key|
      [ column, (BigDecimal(entry[key].to_s) * 1_000_000).round(4) ] if entry[key].is_a?(Numeric)
    end.to_h
  end
end
