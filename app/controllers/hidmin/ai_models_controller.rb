# Models & prices (SCRUM-70): the reference price list. Filled in by Task 14.
class Hidmin::AiModelsController < Hidmin::BaseController
  def index
    @models = AiModel.order(:model_id)
  end

  def update
    head :not_implemented
  end

  def read
    head :not_implemented
  end
end
