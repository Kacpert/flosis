# Models & prices (SCRUM-70): what Anthropic charges per 1M tokens, in
# dollars — read daily (AiPriceRead), typed by hand where a read fails. A
# typed price is saved as soon as its field is left, and stands until the
# next successful read. Reference only: runs are priced from reported cost.
class Hidmin::AiModelsController < Hidmin::BaseController
  PRICE_FIELDS = AiPriceRead::FIELDS.keys.map(&:to_s).freeze

  def index
    AiModel.seed!
    @models = AiModel.includes(:ai_plan_models).order(:model_id)
    @last_read = @models.filter_map(&:read_at).max
  end

  def update
    model = AiModel.find(params[:id])
    field = params[:field].to_s
    value = params[:value].to_s.strip
    return head :unprocessable_entity unless PRICE_FIELDS.include?(field)

    price = value.empty? ? nil : BigDecimal(value, exception: false)
    return head :unprocessable_entity if !value.empty? && (price.nil? || price.negative?)

    model.update!(field => price, price_source: "hand", hand_set_at: Time.current)
    head :no_content
  end

  def read
    result = AiPriceRead.new.call
    redirect_to hidmin_ai_models_path,
                flash: { clar_toast: "#{result[:updated]} of #{result[:updated] + result[:failed]} prices updated" }
  end
end
